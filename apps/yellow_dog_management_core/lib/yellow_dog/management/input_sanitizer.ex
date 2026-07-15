defmodule YellowDog.Management.InputSanitizer do
  @moduledoc false

  @max_id_bytes 128
  @max_name_bytes 128
  @max_status_bytes 64
  @max_metadata_entries 20
  @max_metadata_key_bytes 64
  @max_metadata_value_bytes 256
  @stable_status_atoms [:registered, :online, :offline]
  @stable_metadata_keys [:site]

  def required_string(value, key) when is_binary(value) and value != "" do
    if byte_size(value) <= @max_id_bytes do
      {:ok, value}
    else
      {:error, {:invalid, key}}
    end
  end

  def required_string(_value, key), do: {:error, {:required, key}}

  def optional_string(nil), do: nil

  def optional_string(value) when is_binary(value) do
    trim_binary(value, @max_name_bytes)
  end

  def optional_string(value),
    do: value |> inspect(limit: 20, printable_limit: @max_name_bytes) |> optional_string()

  def status(value) when value in @stable_status_atoms, do: value
  def status(value) when is_atom(value), do: value |> Atom.to_string() |> status()
  def status(value) when is_binary(value), do: trim_binary(value, @max_status_bytes)

  def status(value),
    do: value |> inspect(limit: 20, printable_limit: @max_status_bytes) |> status()

  def datetime(%DateTime{} = value), do: value
  def datetime(_value), do: nil

  def flags(flags, known_keys) when is_map(flags) do
    Enum.reduce(known_keys, %{}, fn key, acc ->
      case get_flag(flags, key) do
        value when is_boolean(value) -> Map.put(acc, key, value)
        _value -> acc
      end
    end)
  end

  def flags(_flags, _known_keys), do: %{}

  def metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.take(@max_metadata_entries)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case {metadata_key(key), metadata_value(value)} do
        {{:ok, key}, {:ok, value}} -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end

  def metadata(_metadata), do: %{}

  defp get_flag(flags, key) do
    cond do
      Map.has_key?(flags, key) -> Map.get(flags, key)
      Map.has_key?(flags, Atom.to_string(key)) -> Map.get(flags, Atom.to_string(key))
      true -> nil
    end
  end

  defp metadata_key(key) when key in @stable_metadata_keys, do: {:ok, key}
  defp metadata_key(key) when is_atom(key), do: key |> Atom.to_string() |> metadata_key()

  defp metadata_key(key) when is_binary(key) and key != "" do
    {:ok, trim_binary(key, @max_metadata_key_bytes)}
  end

  defp metadata_key(_key), do: :error

  defp metadata_value(value) when is_binary(value) do
    {:ok, trim_binary(value, @max_metadata_value_bytes)}
  end

  defp metadata_value(value) when value in @stable_status_atoms, do: {:ok, value}

  defp metadata_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> metadata_value()

  defp metadata_value(value) when is_boolean(value) or is_integer(value) or is_float(value) do
    {:ok, value}
  end

  defp metadata_value(%DateTime{} = value), do: {:ok, value}

  defp metadata_value(value) do
    inspected = inspect(value, limit: 20, printable_limit: @max_metadata_value_bytes)
    {:ok, trim_binary(inspected, @max_metadata_value_bytes)}
  end

  defp trim_binary(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp trim_binary(value, max_bytes) do
    trim_to_valid_utf8(value, max_bytes)
  end

  defp trim_to_valid_utf8(_value, 0), do: ""

  defp trim_to_valid_utf8(value, max_bytes) do
    trimmed = binary_part(value, 0, max_bytes)
    if String.valid?(trimmed), do: trimmed, else: trim_to_valid_utf8(value, max_bytes - 1)
  end
end
