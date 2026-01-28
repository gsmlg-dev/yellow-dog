defmodule YellowDog.DHCP.SafeWriter do
  @moduledoc """
  Atomic file write operations with validation, backup, and rollback.

  Implements a transaction protocol for safe file updates:
  1. Generate unique transaction ID
  2. Write to staging (.cache) directory
  3. Validate written content (round-trip parse)
  4. Backup existing file if present
  5. Atomic rename from staging to target
  6. Cleanup backup on success

  On failure at any step, the original file is preserved or restored.
  """

  import Bitwise
  require Logger

  @type validator :: (String.t() -> :ok | {:error, term()})
  @type transaction_id :: String.t()

  @doc """
  Writes content to a file atomically with validation and backup.

  ## Parameters
  - `path` - Target file path
  - `content` - Content to write
  - `opts` - Options:
    - `:validator` - Function to validate content after write (default: no-op)
    - `:cache_dir` - Directory for staging files (default: sibling .cache dir)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure (original file preserved)

  ## Example

      iex> SafeWriter.write("config.toml", content, validator: &Toml.decode/1)
      :ok

  """
  @spec write(Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write(path, content, opts \\ []) do
    validator = Keyword.get(opts, :validator, fn _ -> :ok end)
    cache_dir = Keyword.get(opts, :cache_dir, default_cache_dir(path))

    tx_id = generate_transaction_id()

    with :ok <- ensure_cache_dir(cache_dir),
         {:ok, cache_path} <- write_to_cache(cache_dir, tx_id, content),
         :ok <- validate_cached_content(cache_path, validator),
         {:ok, backup_path} <- backup_existing(path, cache_dir, tx_id),
         :ok <- atomic_rename(cache_path, path) do
      # Success - cleanup backup
      cleanup_backup(backup_path)

      :telemetry.execute(
        [:yellow_dog, :dhcp, :safe_writer, :write_success],
        %{count: 1},
        %{path: path, tx_id: tx_id}
      )

      :ok
    else
      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :dhcp, :safe_writer, :write_failed],
          %{count: 1},
          %{path: path, tx_id: tx_id, reason: inspect(reason)}
        )

        # Cleanup any staging files
        cleanup_transaction(cache_dir, tx_id)
        error
    end
  end

  @doc """
  Executes a function within a transaction context.

  Provides the cache path for the function to write to. If the function
  succeeds, the cache file is atomically moved to the target path.

  ## Parameters
  - `path` - Target file path
  - `fun` - Function receiving cache_path, should return `:ok` or `{:error, reason}`
  - `opts` - Same options as `write/3`

  ## Example

      SafeWriter.with_transaction("data.toml", fn cache_path ->
        File.write(cache_path, generate_content())
      end)

  """
  @spec with_transaction(Path.t(), (Path.t() -> :ok | {:error, term()}), keyword()) ::
          :ok | {:error, term()}
  def with_transaction(path, fun, opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, default_cache_dir(path))
    validator = Keyword.get(opts, :validator, fn _ -> :ok end)

    tx_id = generate_transaction_id()

    with :ok <- ensure_cache_dir(cache_dir),
         cache_path = Path.join(cache_dir, "#{tx_id}.toml"),
         :ok <- fun.(cache_path),
         :ok <- validate_cached_file(cache_path, validator),
         {:ok, backup_path} <- backup_existing(path, cache_dir, tx_id),
         :ok <- atomic_rename(cache_path, path) do
      cleanup_backup(backup_path)
      :ok
    else
      {:error, _} = error ->
        cleanup_transaction(cache_dir, tx_id)
        error
    end
  end

  @doc """
  Validates content can be parsed back (round-trip validation).

  Useful as a validator function for TOML files.

  ## Example

      SafeWriter.write(path, toml_content, validator: &SafeWriter.validate_toml/1)

  """
  @spec validate_toml(String.t()) :: :ok | {:error, term()}
  def validate_toml(content) do
    case Toml.decode(content) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:toml_validation_failed, reason}}
    end
  end

  @doc """
  Returns the default cache directory for a given path.

  The cache directory is a `.cache` sibling directory to the target file.
  """
  @spec default_cache_dir(Path.t()) :: Path.t()
  def default_cache_dir(path) do
    Path.join(Path.dirname(path), ".cache")
  end

  # Private functions

  @spec generate_transaction_id() :: transaction_id()
  defp generate_transaction_id do
    # UUID v4 for unique transaction identification
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      c ||| 0x4000,
      d ||| 0x8000,
      e
    ])
    |> IO.iodata_to_binary()
  end

  @spec ensure_cache_dir(Path.t()) :: :ok | {:error, term()}
  defp ensure_cache_dir(cache_dir) do
    case File.mkdir_p(cache_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cache_dir_creation_failed, reason}}
    end
  end

  @spec write_to_cache(Path.t(), transaction_id(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  defp write_to_cache(cache_dir, tx_id, content) do
    cache_path = Path.join(cache_dir, "#{tx_id}.toml")

    case File.write(cache_path, content) do
      :ok -> {:ok, cache_path}
      {:error, reason} -> {:error, {:cache_write_failed, reason}}
    end
  end

  @spec validate_cached_content(Path.t(), validator()) :: :ok | {:error, term()}
  defp validate_cached_content(cache_path, validator) do
    case File.read(cache_path) do
      {:ok, content} ->
        case validator.(content) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:validation_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:cache_read_failed, reason}}
    end
  end

  @spec validate_cached_file(Path.t(), validator()) :: :ok | {:error, term()}
  defp validate_cached_file(cache_path, validator) do
    case File.read(cache_path) do
      {:ok, content} ->
        case validator.(content) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:validation_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  @spec backup_existing(Path.t(), Path.t(), transaction_id()) ::
          {:ok, Path.t() | nil} | {:error, term()}
  defp backup_existing(path, cache_dir, tx_id) do
    if File.exists?(path) do
      backup_path = Path.join(cache_dir, "#{tx_id}.backup")

      case File.copy(path, backup_path) do
        {:ok, _} -> {:ok, backup_path}
        {:error, reason} -> {:error, {:backup_failed, reason}}
      end
    else
      {:ok, nil}
    end
  end

  @spec atomic_rename(Path.t(), Path.t()) :: :ok | {:error, term()}
  defp atomic_rename(source, target) do
    # Ensure target directory exists
    target_dir = Path.dirname(target)

    with :ok <- File.mkdir_p(target_dir),
         :ok <- File.rename(source, target) do
      :ok
    else
      {:error, reason} -> {:error, {:atomic_rename_failed, reason}}
    end
  end

  @spec cleanup_backup(Path.t() | nil) :: :ok
  defp cleanup_backup(nil), do: :ok

  defp cleanup_backup(backup_path) do
    File.rm(backup_path)
    :ok
  end

  @spec cleanup_transaction(Path.t(), transaction_id()) :: :ok
  defp cleanup_transaction(cache_dir, tx_id) do
    # Clean up all files with this transaction ID
    cache_path = Path.join(cache_dir, "#{tx_id}.toml")
    backup_path = Path.join(cache_dir, "#{tx_id}.backup")

    File.rm(cache_path)
    File.rm(backup_path)
    :ok
  end

  @doc """
  Restores a file from backup if the backup exists.

  ## Parameters
  - `path` - Target file path to restore
  - `backup_path` - Path to the backup file

  ## Returns
  - `:ok` if restored successfully
  - `{:error, :no_backup}` if backup doesn't exist
  - `{:error, reason}` on failure
  """
  @spec restore_from_backup(Path.t(), Path.t()) :: :ok | {:error, term()}
  def restore_from_backup(path, backup_path) do
    if File.exists?(backup_path) do
      case File.rename(backup_path, path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:restore_failed, reason}}
      end
    else
      {:error, :no_backup}
    end
  end

  @doc """
  Lists pending transactions in a cache directory.

  Useful for recovery after crash - identifies incomplete transactions.

  ## Parameters
  - `cache_dir` - Cache directory to scan

  ## Returns
  - List of transaction IDs with pending state
  """
  @spec list_pending_transactions(Path.t()) :: [%{tx_id: String.t(), files: [String.t()]}]
  def list_pending_transactions(cache_dir) do
    case File.ls(cache_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".toml"))
        |> Enum.map(fn file ->
          tx_id = Path.rootname(file)

          has_backup = File.exists?(Path.join(cache_dir, "#{tx_id}.backup"))

          %{
            tx_id: tx_id,
            has_backup: has_backup,
            files: [file | (if has_backup, do: ["#{tx_id}.backup"], else: [])]
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Cleans up stale transactions older than the specified age.

  ## Parameters
  - `cache_dir` - Cache directory to clean
  - `max_age_seconds` - Maximum age in seconds (default: 3600 = 1 hour)

  ## Returns
  - `{:ok, count}` - Number of transactions cleaned
  """
  @spec cleanup_stale_transactions(Path.t(), pos_integer()) :: {:ok, non_neg_integer()}
  def cleanup_stale_transactions(cache_dir, max_age_seconds \\ 3600) do
    now = System.system_time(:second)

    case File.ls(cache_dir) do
      {:ok, files} ->
        cleaned =
          files
          |> Enum.filter(fn file ->
            path = Path.join(cache_dir, file)

            case File.stat(path, time: :posix) do
              {:ok, %{mtime: mtime}} ->
                now - mtime > max_age_seconds

              _ ->
                false
            end
          end)
          |> Enum.map(fn file ->
            File.rm(Path.join(cache_dir, file))
          end)
          |> Enum.count(&(&1 == :ok))

        {:ok, cleaned}

      {:error, _} ->
        {:ok, 0}
    end
  end
end
