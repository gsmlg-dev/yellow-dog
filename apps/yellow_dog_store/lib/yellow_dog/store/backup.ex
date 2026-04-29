defmodule YellowDog.Store.Backup do
  @moduledoc """
  Backup and restore operations for Concord data.

  Wraps `Concord.Backup` with telemetry, safety latches,
  and YellowDog-specific metadata.
  """

  require Logger

  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend

  @default_backup_dir "./backups"
  @backup_extension ".backup"
  @local_source :yellow_dog_store

  @doc """
  Returns the default backup directory. Controllers and CLI should call this
  so the backup location is always consistent with `create/1` and `list/1`.
  """
  @spec default_dir() :: String.t()
  def default_dir do
    Application.get_env(:yellow_dog, :backup_dir, @default_backup_dir)
  end

  @doc """
  Create a compressed backup of all Concord data.

  ## Options

    * `:dir` — output directory (default: `"./backups"`)
    * `:label` — human-readable label embedded in metadata

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec create(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create(opts \\ []) do
    start = System.monotonic_time()
    backup_opts = [path: Keyword.get(opts, :dir, default_dir())]

    if Backend.active() == EtsBackend do
      create_active_backend_backup(
        backup_opts[:path],
        Keyword.get(opts, :label),
        start
      )
    else
      create_cluster_backup(backup_opts, opts, start)
    end
  end

  defp create_cluster_backup(backup_opts, opts, start) do
    case create_concord_backup(backup_opts) do
      {:ok, path} ->
        duration = System.monotonic_time() - start
        size = file_size(path)

        :telemetry.execute(
          [:yellow_dog, :store, :backup, :created],
          %{duration: duration, size_bytes: size},
          %{path: path, label: Keyword.get(opts, :label)}
        )

        {:ok, path}

      {:error, reason} ->
        if fallback_reason?(reason) do
          # WORKAROUND(upstream): gsmlg-dev/concord#10
          create_active_backend_backup(
            backup_opts[:path],
            Keyword.get(opts, :label),
            start
          )
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Restore Concord data from a backup file.

  ## Options

    * `:verify_only` — validate without applying (default: false)
    * `:confirm` — required `true` to proceed (safety latch)

  Returns `{:ok, stats}` or `{:error, reason}`.
  """
  @spec restore(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore(path, opts \\ []) do
    with :ok <- validate_backup_path(path) do
      confirm = Keyword.get(opts, :confirm, false)
      verify_only = Keyword.get(opts, :verify_only, false)

      cond do
        verify_only ->
          do_verify(path)

        not confirm ->
          {:error, :confirm_required}

        true ->
          do_restore(path)
      end
    end
  end

  @doc """
  Verify backup integrity without restoring.

  Returns `{:ok, stats}` or `{:error, reason}`.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, term()}
  def verify(path) do
    with :ok <- validate_backup_path(path) do
      do_verify(path)
    end
  end

  defp do_verify(path) do
    start = System.monotonic_time()

    case Concord.Backup.verify(path) do
      {:ok, :valid} ->
        duration = System.monotonic_time() - start

        :telemetry.execute(
          [:yellow_dog, :store, :backup, :verified],
          %{duration: duration},
          %{path: path, valid: true}
        )

        {:ok, %{valid: true, path: path}}

      {:ok, :invalid} ->
        {:ok, %{valid: false, path: path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List available backups in a directory.

  Returns `{:ok, [%{path, timestamp, size_bytes, entry_count}]}`.
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    dir = Keyword.get(opts, :dir, default_dir())
    Concord.Backup.list(dir)
  end

  @doc """
  Delete a backup file. The path must be inside the backup directory.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(path) do
    with :ok <- validate_backup_path(path) do
      case File.rm(path) do
        :ok ->
          :telemetry.execute(
            [:yellow_dog, :store, :backup, :deleted],
            %{},
            %{path: path}
          )

          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  # ── Private ─────────────────────────────────────────────────────

  defp create_concord_backup(opts) do
    Concord.Backup.create(opts)
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
  end

  defp create_active_backend_backup(backup_dir, label, start) do
    with :ok <- File.mkdir_p(backup_dir),
         {:ok, entries} <- active_backend_entries(),
         {:ok, backup_data} <- build_active_backend_backup(entries, label),
         {:ok, path} <- write_backup(backup_dir, backup_data) do
      duration = System.monotonic_time() - start
      size = file_size(path)

      :telemetry.execute(
        [:yellow_dog, :store, :backup, :created],
        %{duration: duration, size_bytes: size},
        %{path: path, label: label}
      )

      {:ok, path}
    end
  end

  defp do_restore(path) do
    start = System.monotonic_time()

    case read_backup(path) do
      {:ok, backup_data} ->
        if active_backend_backup?(backup_data) do
          restore_active_backend_backup(path, backup_data, start)
        else
          restore_concord_backup(path, start)
        end

      {:error, _reason} ->
        restore_concord_backup(path, start)
    end
  end

  defp restore_concord_backup(path, start) do
    case Concord.Backup.restore(path, force: true) do
      :ok ->
        duration = System.monotonic_time() - start
        {keys_restored, namespaces} = collect_restore_stats()

        :telemetry.execute(
          [:yellow_dog, :store, :backup, :restored],
          %{duration: duration, keys_restored: keys_restored},
          %{path: path, namespaces: namespaces}
        )

        {:ok, %{path: path, restored: true, keys_restored: keys_restored, namespaces: namespaces}}

      {:ok, stats} when is_map(stats) ->
        duration = System.monotonic_time() - start
        keys_restored = Map.get(stats, :keys_restored, 0)
        namespaces = Map.get(stats, :namespaces, [])

        :telemetry.execute(
          [:yellow_dog, :store, :backup, :restored],
          %{duration: duration, keys_restored: keys_restored},
          %{path: path, namespaces: namespaces}
        )

        {:ok, %{path: path, restored: true, keys_restored: keys_restored, namespaces: namespaces}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restore_active_backend_backup(path, backup_data, start) do
    with {:ok, :valid} <- verify_checksum(backup_data),
         %{data: %{kv_data: entries}} <- backup_data,
         :ok <- reset_active_backend(),
         {:ok, _results} <- Backend.active().put_many(entries) do
      duration = System.monotonic_time() - start
      keys_restored = length(entries)
      namespaces = namespaces_for_entries(entries)

      :telemetry.execute(
        [:yellow_dog, :store, :backup, :restored],
        %{duration: duration, keys_restored: keys_restored},
        %{path: path, namespaces: namespaces}
      )

      {:ok, %{path: path, restored: true, keys_restored: keys_restored, namespaces: namespaces}}
    else
      {:ok, :invalid} -> {:error, :invalid_backup}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_backup_format}
    end
  end

  defp collect_restore_stats do
    namespace_prefixes = [
      {"dhcp:lease:", :lease},
      {"device:", :device},
      {"dns:zone:", :zone},
      {"dns:dyn:", :dyn_dns},
      {"dns:cache:", :cache},
      {"rpz:", :rpz},
      {"host:", :host},
      {"config:", :config}
    ]

    counts =
      Enum.reduce(namespace_prefixes, %{total: 0, namespaces: []}, fn {prefix, ns}, acc ->
        case YellowDog.Store.Backend.active().prefix_scan(prefix, consistency: :eventual) do
          {:ok, entries} when entries != [] ->
            count = length(entries)
            %{acc | total: acc.total + count, namespaces: [ns | acc.namespaces]}

          _ ->
            acc
        end
      end)

    {counts.total, Enum.reverse(counts.namespaces)}
  rescue
    _ -> {0, []}
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp active_backend_entries do
    Backend.active().prefix_scan("", consistency: :eventual)
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
  end

  defp build_active_backend_backup(entries, label) do
    snapshot_data = %{
      version: 2,
      kv_data: entries,
      indexes: %{},
      source: @local_source
    }

    metadata = %{
      timestamp: DateTime.utc_now(),
      node: node(),
      cluster_name: Application.get_env(:concord, :cluster_name, :concord_cluster),
      entry_count: length(entries),
      state_categories: [:kv],
      state_counts: %{kv: length(entries)},
      memory_bytes: :erlang.external_size(snapshot_data),
      version: concord_version(),
      format_version: 2,
      checksum: compute_checksum(snapshot_data),
      label: label,
      source: @local_source
    }

    {:ok, %{metadata: metadata, data: snapshot_data}}
  end

  defp write_backup(backup_dir, backup_data) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(":", "")
    unique = System.unique_integer([:positive])
    filename = "yellow_dog_backup_#{timestamp}_#{unique}#{@backup_extension}"
    path = Path.join(backup_dir, filename)

    case File.write(path, :erlang.term_to_binary(backup_data, [:compressed])) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_backup(path) do
    case File.read(path) do
      {:ok, binary} ->
        try do
          {:ok, :erlang.binary_to_term(binary)}
        rescue
          _ -> {:error, :invalid_backup_format}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_checksum(%{metadata: %{checksum: expected}, data: data}) do
    if compute_checksum(data) == expected do
      {:ok, :valid}
    else
      {:ok, :invalid}
    end
  end

  defp verify_checksum(_backup_data), do: {:error, :invalid_backup_format}

  defp compute_checksum(data) do
    :crypto.hash(:sha256, :erlang.term_to_binary(data))
  end

  defp reset_active_backend do
    if Backend.active() == EtsBackend do
      EtsBackend.create_table()
      :ets.delete_all_objects(EtsBackend.table())
    end

    :ok
  end

  defp active_backend_backup?(%{metadata: %{source: @local_source}}), do: true
  defp active_backend_backup?(%{data: %{source: @local_source}}), do: true
  defp active_backend_backup?(_backup_data), do: false

  defp namespaces_for_entries(entries) do
    entries
    |> Enum.map(fn {key, _value} -> namespace_for_key(key) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp namespace_for_key("dhcp:lease:" <> _), do: :lease
  defp namespace_for_key("device:" <> _), do: :device
  defp namespace_for_key("dns:zone:" <> _), do: :zone
  defp namespace_for_key("dns:dyn:" <> _), do: :dyn_dns
  defp namespace_for_key("dns:cache:" <> _), do: :cache
  defp namespace_for_key("rpz:" <> _), do: :rpz
  defp namespace_for_key("host:" <> _), do: :host
  defp namespace_for_key("config:" <> _), do: :config
  defp namespace_for_key(_key), do: nil

  defp fallback_reason?(:noproc), do: true
  defp fallback_reason?(:system_not_started), do: true
  defp fallback_reason?(_reason), do: false

  defp concord_version do
    case Application.spec(:concord, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp validate_backup_path(path) do
    backup_dir = Path.expand(default_dir())
    expanded = Path.expand(path)

    if String.starts_with?(expanded, backup_dir <> "/") do
      :ok
    else
      {:error, :path_outside_backup_dir}
    end
  end
end
