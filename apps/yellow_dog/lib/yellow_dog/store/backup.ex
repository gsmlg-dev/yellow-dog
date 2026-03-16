defmodule YellowDog.Store.Backup do
  @moduledoc """
  Backup and restore operations for Concord data.

  Wraps `Concord.Backup` with telemetry, safety latches,
  and YellowDog-specific metadata.
  """

  require Logger

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
    backup_opts = [path: Keyword.get(opts, :dir, "./backups")]

    case Concord.Backup.create(backup_opts) do
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
        {:error, reason}
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
    confirm = Keyword.get(opts, :confirm, false)
    verify_only = Keyword.get(opts, :verify_only, false)

    cond do
      verify_only ->
        verify(path)

      not confirm ->
        {:error, :confirm_required}

      true ->
        do_restore(path)
    end
  end

  @doc """
  Verify backup integrity without restoring.

  Returns `{:ok, stats}` or `{:error, reason}`.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, term()}
  def verify(path) do
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
    dir = Keyword.get(opts, :dir, "./backups")
    Concord.Backup.list(dir)
  end

  @doc """
  Delete a backup file.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(path) do
    File.rm(path)
  end

  # ── Private ─────────────────────────────────────────────────────

  defp do_restore(path) do
    start = System.monotonic_time()

    case Concord.Backup.restore(path, force: true) do
      :ok ->
        duration = System.monotonic_time() - start

        :telemetry.execute(
          [:yellow_dog, :store, :backup, :restored],
          %{duration: duration, keys_restored: 0},
          %{path: path, namespaces: []}
        )

        {:ok, %{path: path, restored: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
