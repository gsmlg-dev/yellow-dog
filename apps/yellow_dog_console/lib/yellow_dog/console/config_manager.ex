defmodule YellowDog.Console.ConfigManager do
  @moduledoc """
  Handles TOML configuration file I/O with structure preservation.

  This module implements line-based partial updates to preserve comments,
  whitespace, and formatting in TOML files while updating configuration values.

  Based on research findings from research.md:
  - Line-based partial update with token parsing
  - Atomic writes using temp file + rename
  - Backup before every save with 10-rotation
  - TOML verification after save
  """

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
    case File.exists?(file_path) do
      false ->
        {:error, :file_not_found}

      true ->
        case Toml.decode_file(file_path) do
          {:ok, config} -> {:ok, config}
          {:error, _} -> {:error, :invalid_toml}
        end
    end
  end

  @doc """
  Saves configuration updates to TOML file with structure preservation.

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
    with {:ok, content} <- File.read(file_path),
         :ok <- maybe_backup(file_path, opts),
         {:ok, updated_content} <- apply_updates(content, updates),
         :ok <- atomic_write(file_path, updated_content),
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
    unless File.exists?(file_path) do
      {:error, :file_not_found}
    else
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
        files
        |> Enum.filter(&String.match?(&1, ~r/^#{Regex.escape(base)}\.backup\.\d{8}T\d{6,}Z$/))
        |> Enum.map(&Path.join(dir, &1))
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
    default_config = """
    # Yellow Dog DNS Configuration

    [core]
    dns = true
    mdns = true
    dhcpv4 = true
    dhcpv6 = true

    [dns]
    listen = "0.0.0.0"
    port = 53

    [mdns]
    listen = "0.0.0.0"
    port = 5353
    mode = "responder"

    [dhcpv4]
    listen = "0.0.0.0"
    port = 67

    [[dhcpv4.pools]]
    name = "default"
    range_start = "192.168.1.100"
    range_end = "192.168.1.200"
    lease_time = 3600
    gateway = "192.168.1.1"
    dns_servers = ["8.8.8.8", "8.8.4.4"]

    [dhcpv6]
    listen = "::"
    port = 547

    [[dhcpv6.pools]]
    name = "default"
    range_start = "2001:db8::100"
    range_end = "2001:db8::200"
    preferred_lifetime = 3600
    valid_lifetime = 7200
    dns_servers = ["2001:4860:4860::8888"]
    """

    File.write(file_path, default_config)
  end

  @doc """
  Creates a minimal valid configuration file.

  Only includes essential fields required for parsing.
  """
  @spec create_minimal_config(String.t()) :: :ok | {:error, term()}
  def create_minimal_config(file_path) do
    minimal_config = """
    [core]
    dns = false
    mdns = false
    dhcpv4 = false
    dhcpv6 = false

    [dns]
    listen = "0.0.0.0"
    port = 53

    [mdns]
    listen = "0.0.0.0"
    port = 5353

    [dhcpv4]
    listen = "0.0.0.0"
    port = 67

    [dhcpv6]
    listen = "::"
    port = 547
    """

    File.write(file_path, minimal_config)
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

  defp apply_updates(content, updates) do
    lines = String.split(content, "\n")
    tokens = parse_tokens(lines)

    # Separate array table updates from regular updates
    {array_updates, regular_updates} =
      Enum.split_with(updates, fn {key, value} ->
        String.ends_with?(key, ".pools") && is_list(value)
      end)

    # Apply regular key=value updates
    updated_lines =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        # Check if this line needs updating
        update_key =
          Enum.find(regular_updates, fn {key_path, _value} ->
            Map.get(tokens, key_path) == idx
          end)

        case update_key do
          {key_path, new_value} -> update_line_value(line, key_path, new_value)
          nil -> line
        end
      end)

    # Handle array table updates (like pools)
    final_lines =
      Enum.reduce(array_updates, updated_lines, fn {key, pools}, lines ->
        apply_array_table_update(lines, key, pools)
      end)

    {:ok, Enum.join(final_lines, "\n")}
  end

  defp apply_array_table_update(lines, key, items) do
    # Parse key: "dhcpv4.pools" -> section="dhcpv4", array_name="pools"
    parts = String.split(key, ".")
    section = parts |> Enum.drop(-1) |> Enum.join(".")
    _array_name = List.last(parts)
    array_table_header = "[[#{key}]]"

    # Find section boundaries and remove existing array tables
    {cleaned_lines, section_end_idx} = remove_array_tables(lines, section, array_table_header)

    # Generate new array table entries
    new_pool_lines = generate_array_table_entries(array_table_header, items)

    # Insert new array tables at the end of the section
    insert_at = section_end_idx || length(cleaned_lines)
    result = List.insert_at(cleaned_lines, insert_at, new_pool_lines) |> List.flatten()

    result
  end

  defp remove_array_tables(lines, section, array_table_header) do
    section_header = "[#{section}]"
    in_section? = false
    in_array_table? = false
    section_end_idx = nil

    {result, _, _, last_section_idx} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], in_section?, in_array_table?, section_end_idx}, fn
        {line, idx}, {acc, in_sect, in_arr, sect_end} ->
          trimmed = String.trim(line)

          cond do
            # Entering target section
            trimmed == section_header ->
              {acc ++ [line], true, false, idx}

            # Leaving section (entering another section)
            in_sect && String.match?(trimmed, ~r/^\[/) && trimmed != array_table_header ->
              {acc ++ [line], false, false, sect_end}

            # Entering array table in our section
            in_sect && trimmed == array_table_header ->
              {acc, in_sect, true, sect_end}

            # Inside array table - skip these lines
            in_arr && trimmed == "" ->
              # Empty line might end array table
              {acc, in_sect, false, idx}

            in_arr && String.match?(trimmed, ~r/^\[/) ->
              # Next section/array table starts
              {acc ++ [line], String.match?(trimmed, ~r/^\[#{section}\]/),
               trimmed == array_table_header, idx}

            in_arr ->
              # Skip array table content
              {acc, in_sect, in_arr, idx}

            # Regular line in our section
            in_sect ->
              {acc ++ [line], in_sect, in_arr, idx}

            # Regular line outside our section
            true ->
              {acc ++ [line], in_sect, in_arr, sect_end}
          end
      end)

    {result, last_section_idx}
  end

  defp generate_array_table_entries(header, items) when is_list(items) do
    Enum.flat_map(items, fn item ->
      ["", header] ++ format_table_entries(item)
    end)
  end

  defp format_table_entries(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.sort()
    |> Enum.map(fn {key, value} ->
      encoded = encode_toml_value(value)
      "#{key} = #{encoded}"
    end)
  end

  defp parse_tokens(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce({[], nil}, fn {line, idx}, {tokens, section} ->
      cond do
        String.match?(line, ~r/^\[(.+)\]$/) ->
          section_name = Regex.run(~r/^\[(.+)\]$/, line) |> List.last()
          {tokens, section_name}

        String.match?(line, ~r/^(\w+)\s*=/) ->
          [key | _] = String.split(line, "=")
          key = String.trim(key)
          full_key = if section, do: "#{section}.#{key}", else: key
          {[{full_key, idx} | tokens], section}

        true ->
          {tokens, section}
      end
    end)
    |> elem(0)
    |> Map.new()
  end

  defp update_line_value(line, key, value) do
    key_name = key |> String.split(".") |> List.last()
    encoded_value = encode_toml_value(value)

    pattern_str = "^(\\s*#{Regex.escape(key_name)}\\s*=\\s*).*$"
    pattern = Regex.compile!(pattern_str)

    Regex.replace(pattern, line, fn _, prefix ->
      "#{prefix}#{encoded_value}"
    end)
  end

  defp encode_toml_value(value) when is_binary(value), do: "\"#{value}\""
  defp encode_toml_value(value) when is_boolean(value), do: to_string(value)
  defp encode_toml_value(value) when is_integer(value), do: to_string(value)

  defp encode_toml_value(value) when is_list(value) do
    "[" <> Enum.map_join(value, ", ", &encode_toml_value/1) <> "]"
  end

  defp encode_toml_value(value) when is_map(value) do
    "{" <>
      Enum.map_join(value, ", ", fn {k, v} ->
        "#{k} = #{encode_toml_value(v)}"
      end) <> "}"
  end

  defp atomic_write(file_path, content) do
    temp_path = "#{file_path}.tmp"

    with :ok <- File.write(temp_path, content),
         :ok <- File.rename(temp_path, file_path) do
      :ok
    else
      error ->
        File.rm(temp_path)
        error
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
