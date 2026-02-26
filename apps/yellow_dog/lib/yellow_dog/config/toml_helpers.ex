defmodule YellowDog.Config.TomlHelpers do
  @moduledoc """
  Shared helpers for reading TOML-parsed maps and writing TOML content.

  TOML parsers may produce maps with atom or string keys depending on the
  parser and configuration. These helpers try both key forms so callers
  don't need to worry about which variant they received.
  """

  # ──────────────────────────────────────────────────────────────────
  # Map Accessors — polymorphic over atom/string keys
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Finds the first matching key's value, returning `default` if none match.

  Uses `Map.has_key?/2` instead of `Enum.find_value/3` so that falsy values
  like `false` and `0` are correctly returned rather than skipped.
  """
  @spec get_value(map(), [atom() | String.t()], term()) :: term()
  def get_value(map, keys, default \\ nil) do
    case Enum.find(keys, fn key -> Map.has_key?(map, key) end) do
      nil -> default
      key -> Map.get(map, key)
    end
  end

  @doc "Like `get_value/3` but coerces the result to an integer."
  @spec get_integer(map(), [atom() | String.t()], integer()) :: integer()
  def get_integer(map, keys, default) do
    case get_value(map, keys, default) do
      value when is_integer(value) -> value
      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end
      _ -> default
    end
  end

  @doc """
  Like `get_value/3` but coerces the result to a boolean.

  Handles `true`/`false` atoms and `"true"`/`"false"` strings.
  """
  @spec get_boolean(map(), [atom() | String.t()], boolean()) :: boolean()
  def get_boolean(map, keys, default) do
    case get_value(map, keys) do
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  @doc "Like `get_value/3` but returns `default` unless the value is a list."
  @spec get_list(map(), [atom() | String.t()], list()) :: list()
  def get_list(map, keys, default \\ []) do
    case get_value(map, keys) do
      nil -> default
      value when is_list(value) -> value
      _ -> default
    end
  end

  @doc "Like `get_value/3` but returns `default` unless the value is a map."
  @spec get_map(map(), [atom() | String.t()], map()) :: map()
  def get_map(map, keys, default) do
    case get_value(map, keys) do
      nil -> default
      value when is_map(value) -> value
      _ -> default
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # TOML Parsing
  # ──────────────────────────────────────────────────────────────────

  @doc "Decodes a TOML string, wrapping parse errors in `{:error, {:toml_parse_error, reason}}`."
  @spec parse_toml(String.t()) :: {:ok, map()} | {:error, {:toml_parse_error, term()}}
  def parse_toml(content) do
    case Toml.decode(content) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:toml_parse_error, reason}}
    end
  end

  @doc "Reads a file and decodes it as TOML. Returns `{:ok, []}` for missing files."
  @spec read_toml_file(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_toml_file(path) do
    with {:ok, content} <- File.read(path), do: parse_toml(content)
  end

  # ──────────────────────────────────────────────────────────────────
  # TOML Serialization Helpers
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Encodes an Elixir value to a TOML-compatible value string.

  Handles strings, booleans, integers, floats, lists, and maps.
  Delegates to `YellowDog.Config.TomlEncoder.encode_value/1`.

  ## Examples

      iex> encode_toml_value("hello")
      ~S("hello")

      iex> encode_toml_value(53)
      "53"

      iex> encode_toml_value(true)
      "true"

      iex> encode_toml_value(["a", "b"])
      ~S(["a", "b"])
  """
  @spec encode_toml_value(term()) :: String.t()
  defdelegate encode_toml_value(value), to: YellowDog.Config.TomlEncoder, as: :encode_value

  @doc "Wraps a binary in TOML double-quotes, escaping inner quotes."
  @spec encode_toml_string(term()) :: String.t()
  def encode_toml_string(value) when is_binary(value) do
    "\"#{String.replace(value, "\"", "\\\"")}\""
  end

  def encode_toml_string(value), do: inspect(value)

  @doc """
  Writes `content` to `file_path` atomically via a temporary file.

  Creates parent directories if needed. On error the temp file is cleaned up.
  For production persistence with validation and backup, prefer
  `YellowDog.DHCP.SafeWriter.write/3`.
  """
  @spec atomic_write(Path.t(), String.t()) :: :ok | {:error, term()}
  def atomic_write(file_path, content) do
    dir = Path.dirname(file_path)
    tmp_path = file_path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, file_path) do
      :ok
    else
      error ->
        File.rm(tmp_path)
        error
    end
  end

  @doc "Ensures the parent directory of `file_path` exists."
  @spec ensure_directory(Path.t()) :: :ok | {:error, term()}
  def ensure_directory(file_path) do
    dir = Path.dirname(file_path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      error -> error
    end
  end

  @doc "Formats a datetime value to ISO 8601 string for TOML serialization."
  @spec format_datetime(DateTime.t() | integer() | term()) :: String.t()
  def format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  def format_datetime(unix) when is_integer(unix),
    do: DateTime.to_iso8601(DateTime.from_unix!(unix))

  def format_datetime(_), do: DateTime.to_iso8601(DateTime.utc_now())

  @doc "Creates a `.backup` copy of `file_path` if `backup?` is true and the file exists."
  @spec maybe_create_backup(Path.t(), boolean()) :: :ok | {:error, term()}
  def maybe_create_backup(_file_path, false), do: :ok

  def maybe_create_backup(file_path, true) do
    if File.exists?(file_path) do
      backup_path = file_path <> ".backup"
      File.cp(file_path, backup_path)
    else
      :ok
    end
  end
end
