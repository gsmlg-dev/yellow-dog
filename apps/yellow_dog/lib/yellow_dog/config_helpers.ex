defmodule YellowDog.ConfigHelpers do
  @moduledoc """
  Shared configuration parsing helpers for maps with mixed atom/string keys.

  Provides `get_value/3` for dual-key lookups (atom then string fallback),
  conditional map insertion helpers (`maybe_put`), and parsing utilities
  for datetimes, lease states, and option codes.
  """

  @doc """
  Gets a value from a config map by atom key, falling back to string key.

  Useful for maps that may have atom or string keys (e.g., from TOML parsing).

  ## Examples

      iex> ConfigHelpers.get_value(%{name: "foo"}, :name)
      "foo"

      iex> ConfigHelpers.get_value(%{"name" => "foo"}, :name)
      "foo"

      iex> ConfigHelpers.get_value(%{}, :name, "default")
      "default"
  """
  @spec get_value(map(), atom(), term()) :: term()
  def get_value(config, key, default \\ nil) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(config, key) -> Map.get(config, key)
      Map.has_key?(config, string_key) -> Map.get(config, string_key)
      true -> default
    end
  end

  @doc """
  Parses a lease state from an atom or string.

  ## Examples

      iex> ConfigHelpers.parse_state(:active)
      :active

      iex> ConfigHelpers.parse_state("declined")
      :declined

      iex> ConfigHelpers.parse_state("unknown")
      :active
  """
  @spec parse_state(atom() | String.t()) :: atom()
  def parse_state(state) when is_atom(state), do: state
  def parse_state("active"), do: :active
  def parse_state("offered"), do: :offered
  def parse_state("declined"), do: :declined
  def parse_state("released"), do: :released
  def parse_state("expired"), do: :expired
  def parse_state(_), do: :active

  @doc """
  Parses a datetime value from various formats.

  Accepts `nil` (returns current UTC time), `DateTime` structs,
  ISO 8601 strings, and Unix timestamps.

  ## Examples

      iex> {:ok, %DateTime{}} = ConfigHelpers.parse_datetime(nil)

      iex> {:ok, dt} = ConfigHelpers.parse_datetime("2024-01-01T00:00:00Z")
  """
  @spec parse_datetime(nil | DateTime.t() | String.t() | integer()) ::
          {:ok, DateTime.t()} | {:error, String.t()}
  def parse_datetime(nil), do: {:ok, DateTime.utc_now()}
  def parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  def parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, "Invalid datetime format"}
    end
  end

  def parse_datetime(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> {:error, "Unix timestamp out of range"}
    end
  end

  def parse_datetime(_), do: {:error, "Invalid datetime"}

  @doc """
  Parses an integer option code from an integer, string, or other value.

  ## Examples

      iex> ConfigHelpers.parse_option_code(42)
      42

      iex> ConfigHelpers.parse_option_code("42")
      42

      iex> ConfigHelpers.parse_option_code("abc")
      0
  """
  @spec parse_option_code(integer() | String.t() | term()) :: integer()
  def parse_option_code(code) when is_integer(code), do: code

  def parse_option_code(code) when is_binary(code) do
    case Integer.parse(code) do
      {int, ""} -> int
      _ -> 0
    end
  end

  def parse_option_code(code), do: parse_option_code(to_string(code))

  @doc """
  Partitions a list of `{:ok, val} | {:error, reason}` results.

  Returns `{:ok, values}` if all results are ok, `{:error, errors}` otherwise.
  """
  @spec collect_ok([{:ok, term()} | {:error, term()}]) ::
          {:ok, [term()]} | {:error, [{:error, term()}]}
  def collect_ok(results) do
    {oks, errors} = Enum.split_with(results, &match?({:ok, _}, &1))

    if errors == [] do
      {:ok, Enum.map(oks, fn {:ok, val} -> val end)}
    else
      {:error, errors}
    end
  end

  @doc """
  Conditionally puts a value into a map, skipping `nil` values.
  """
  @spec maybe_put(map(), String.t(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Conditionally puts a list into a map, skipping empty lists.
  """
  @spec maybe_put_list(map(), String.t(), list()) :: map()
  def maybe_put_list(map, _key, []), do: map
  def maybe_put_list(map, key, list), do: Map.put(map, key, list)

  @doc """
  Conditionally puts a map value, skipping `nil` and empty maps.
  """
  @spec maybe_put_map(map(), String.t(), map() | nil) :: map()
  def maybe_put_map(map, _key, nil), do: map
  def maybe_put_map(map, _key, m) when map_size(m) == 0, do: map
  def maybe_put_map(map, key, value), do: Map.put(map, key, value)
end
