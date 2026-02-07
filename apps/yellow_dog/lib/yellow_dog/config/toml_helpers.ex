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

  @doc "Finds the first matching key's value, returning `default` if none match."
  @spec get_value(map(), [atom() | String.t()], term()) :: term()
  def get_value(map, keys, default \\ nil) do
    Enum.find_value(keys, default, fn key -> Map.get(map, key) end)
  end

  @doc "Like `get_value/3` but coerces the result to an integer."
  @spec get_integer(map(), [atom() | String.t()], integer()) :: integer()
  def get_integer(map, keys, default) do
    case get_value(map, keys, default) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> default
    end
  end

  @doc """
  Like `get_value/3` but coerces the result to a boolean.

  Handles `true`/`false` atoms and `"true"`/`"false"` strings.
  Uses explicit key lookup because `Enum.find_value` treats `false` as "not found".
  """
  @spec get_boolean(map(), [atom() | String.t()], boolean()) :: boolean()
  def get_boolean(map, keys, default) do
    found_key = Enum.find(keys, fn key -> Map.has_key?(map, key) end)

    case found_key do
      nil ->
        default

      key ->
        case Map.get(map, key) do
          value when is_boolean(value) -> value
          "true" -> true
          "false" -> false
          _ -> default
        end
    end
  end

  @doc "Like `get_value/3` but returns `default` unless the value is a list."
  @spec get_list(map(), [atom() | String.t()], list()) :: list()
  def get_list(map, keys, default \\ []) do
    case Enum.find_value(keys, fn key -> Map.get(map, key) end) do
      nil -> default
      value when is_list(value) -> value
      _ -> default
    end
  end

  @doc "Like `get_value/3` but returns `default` unless the value is a map."
  @spec get_map(map(), [atom() | String.t()], map()) :: map()
  def get_map(map, keys, default) do
    case Enum.find_value(keys, fn key -> Map.get(map, key) end) do
      nil -> default
      value when is_map(value) -> value
      _ -> default
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # TOML Serialization Helpers
  # ──────────────────────────────────────────────────────────────────

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
    File.mkdir_p!(dir)

    tmp_path = file_path <> ".tmp"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, file_path) do
      :ok
    else
      error ->
        File.rm(tmp_path)
        error
    end
  end
end
