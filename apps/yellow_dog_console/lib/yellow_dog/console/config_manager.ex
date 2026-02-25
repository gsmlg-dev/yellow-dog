defmodule YellowDog.Console.ConfigManager do
  @moduledoc """
  Handles TOML configuration file I/O for the YellowDog Console.

  Uses a parse → modify → encode → write pipeline via `YellowDog.Config.Writer`
  and `YellowDog.Config.TomlEncoder`. Unlike the previous line-based regex
  patcher, this approach can create new sections and keys freely.

  Features:
  - Atomic writes using temp file + rename
  - Backup before every save with 10-rotation
  - TOML verification after save
  - Pre-write validation via `YellowDog.Config.Schema`
  """

  alias YellowDog.Config.{Schema, Writer}

  @doc """
  Loads configuration from a TOML file.

  ## Parameters
    - file_path: Absolute path to TOML configuration file

  ## Returns
    - `{:ok, config}` where config is a map of parsed TOML
    - `{:error, :file_not_found}` if file doesn't exist
    - `{:error, :invalid_toml}` if file is corrupted

  ## Examples

      iex> ConfigManager.load_config("/path/to/config.toml")
      {:ok, %{"dns" => %{"port" => 53, "listen" => "0.0.0.0"}}}
  """
  @spec load_config(String.t()) :: {:ok, map()} | {:error, :file_not_found | :invalid_toml}
  def load_config(file_path) do
    if File.exists?(file_path) do
      case Toml.decode_file(file_path) do
        {:ok, config} -> {:ok, config}
        {:error, _} -> {:error, :invalid_toml}
      end
    else
      {:ok, Schema.defaults()}
    end
  end

  @doc """
  Saves configuration updates to TOML file.

  Loads the current config, applies dot-notation updates, validates,
  encodes to TOML, and writes atomically.

  ## Options
    - `:backup` - Create backup before save (default: true)
    - `:verify` - Verify TOML parse after save (default: true)

  ## Parameters
    - file_path: Path to TOML file
    - updates: Map of "section.key" => value updates
    - opts: Keyword list of options

  ## Returns
    - `:ok` on success
    - `{:error, reason}` on failure

  ## Examples

      iex> updates = %{"dns.port" => 5353, "dns.listen" => "127.0.0.1"}
      iex> ConfigManager.save_config("/path/to/config.toml", updates, backup: true)
      :ok
  """
  @spec save_config(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save_config(file_path, updates, opts \\ []) do
    with {:ok, config} <- load_config(file_path),
         :ok <- maybe_backup(file_path, opts),
         updated = Writer.apply_updates(config, updates),
         :ok <- Writer.write_config(file_path, updated, validate: false),
         :ok <- maybe_verify(file_path, opts) do
      :ok
    end
  end

  @doc """
  Alias for `save_config/3` with default options.

  Updates configuration file with the given changes.

  ## Parameters
    - file_path: Path to TOML file
    - updates: Map of "section.key" => value updates

  ## Returns
    - `:ok` on success
    - `{:error, reason}` on failure
  """
  @spec update_config(String.t(), map()) :: :ok | {:error, term()}
  def update_config(file_path, updates) do
    save_config(file_path, updates, backup: true, verify: true)
  end

  @doc """
  Creates a timestamped backup of the configuration file.

  Automatically rotates old backups to keep only the last 10.

  ## Returns
    - `{:ok, backup_path}` with path to created backup
    - `{:error, reason}` on failure
  """
  @spec create_backup(String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_backup(file_path) do
    if File.exists?(file_path) do
      # Use microseconds to ensure unique filenames
      timestamp =
        DateTime.utc_now()
        |> DateTime.to_iso8601(:basic)
        |> String.replace(~r/[:\-\.]/, "")

      backup_path = "#{file_path}.backup.#{timestamp}"

      with :ok <- rotate_backups(file_path, max_backups: 10),
           {:ok, _} <- File.copy(file_path, backup_path) do
        {:ok, backup_path}
      end
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Lists all backup files for a configuration file.

  Returns sorted list (oldest first).
  """
  @spec list_backups(String.t()) :: [String.t()]
  def list_backups(file_path) do
    dir = Path.dirname(file_path)
    base = Path.basename(file_path)

    case File.ls(dir) do
      {:ok, files} ->
        for(
          f <- files,
          f =~ ~r/^#{Regex.escape(base)}\.backup\.\d{8}T\d{6,}Z$/,
          do: Path.join(dir, f)
        )
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Restores configuration from a backup file.

  Creates a backup of current config before restoring.
  """
  @spec restore_backup(String.t(), String.t()) :: :ok | {:error, term()}
  def restore_backup(file_path, backup_path) do
    with {:ok, _current_backup} <- create_backup(file_path),
         {:ok, _} <- File.copy(backup_path, file_path) do
      :ok
    end
  end

  @doc """
  Creates a default configuration file.

  Uses built-in default values for all services.
  """
  @spec create_default_config(String.t()) :: :ok | {:error, term()}
  def create_default_config(file_path) do
    Writer.write_defaults(file_path)
  end

  @doc """
  Creates a minimal valid configuration file.

  Only includes essential fields required for parsing.
  """
  @spec create_minimal_config(String.t()) :: :ok | {:error, term()}
  def create_minimal_config(file_path) do
    Writer.write_minimal(file_path)
  end

  # Private Functions

  defp maybe_backup(file_path, opts) do
    if Keyword.get(opts, :backup, true) do
      case create_backup(file_path) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  defp maybe_verify(file_path, opts) do
    if Keyword.get(opts, :verify, true) do
      case Toml.decode_file(file_path) do
        {:ok, _} -> :ok
        error -> {:error, {:verification_failed, error}}
      end
    else
      :ok
    end
  end

  defp rotate_backups(file_path, opts) do
    max_backups = Keyword.get(opts, :max_backups, 10)

    backups = list_backups(file_path)

    # Keep space for new backup (max_backups - 1)
    to_delete =
      backups
      |> Enum.sort()
      |> Enum.drop(-(max_backups - 1))

    Enum.each(to_delete, &File.rm/1)

    :ok
  end
end
