defmodule YellowDog.Config.TomlEncoder do
  @moduledoc """
  Encodes Elixir maps to valid TOML strings.

  Replaces the line-based regex patcher in ConfigManager with a proper
  parse → modify → encode → write pipeline. Produces deterministic output
  with sorted keys for stable diffs between saves.

  ## TOML ordering rules

  1. Top-level scalar key/value pairs
  2. `[section]` tables (nested maps)
  3. `[[section.array]]` array tables (lists of maps)

  ## Examples

      iex> TomlEncoder.encode(%{"dns" => %{"port" => 53, "listen" => "0.0.0.0"}})
      "[dns]\\nlisten = \\"0.0.0.0\\"\\nport = 53\\n"
  """

  @doc """
  Encodes a map to a TOML string.

  ## Options

    * `:header` - Optional comment block prepended to the output

  ## Examples

      iex> TomlEncoder.encode(%{"core" => %{"dns" => true}})
      "[core]\\ndns = true\\n"

      iex> TomlEncoder.encode(%{"port" => 53}, header: "# Config file")
      "# Config file\\nport = 53\\n"
  """
  @spec encode(map(), keyword()) :: String.t()
  def encode(map, opts \\ []) when is_map(map) do
    header = Keyword.get(opts, :header)

    {scalars, tables, array_tables} = partition_map(map)

    parts =
      []
      |> maybe_add_header(header)
      |> add_scalars(scalars)
      |> add_tables(tables, [])
      |> add_array_tables(array_tables, [])

    Enum.join(parts, "\n") <> "\n"
  end

  # Partitions a map into {scalars, tables, array_tables}.
  # Scalars: non-map, non-list-of-maps values at this level
  # Tables: map values (become [section])
  # Array tables: list-of-maps values (become [[section]])
  defp partition_map(map) do
    {scalars, tables, array_tables} =
      map
      |> sort_keys()
      |> Enum.reduce({[], [], []}, fn {key, value}, {sc, tb, at} ->
        cond do
          is_map(value) ->
            {sc, [{key, value} | tb], at}

          is_list(value) and value != [] and Enum.all?(value, &is_map/1) ->
            {sc, tb, [{key, value} | at]}

          true ->
            {sc ++ [{key, value}], tb, at}
        end
      end)

    {scalars, Enum.reverse(tables), Enum.reverse(array_tables)}
  end

  defp sort_keys(map) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
  end

  defp maybe_add_header(parts, nil), do: parts

  defp maybe_add_header(parts, header) do
    parts ++ [header]
  end

  defp add_scalars(parts, []), do: parts

  defp add_scalars(parts, scalars) do
    lines = Enum.map(scalars, fn {key, value} -> "#{key} = #{encode_value(value)}" end)
    parts ++ lines
  end

  defp add_tables(parts, [], _prefix), do: parts

  defp add_tables(parts, tables, prefix) do
    Enum.reduce(tables, parts, fn {key, map}, acc ->
      full_key = prefix ++ [key]
      header = "[#{Enum.join(full_key, ".")}]"

      {scalars, nested_tables, nested_array_tables} = partition_map(map)

      scalar_lines =
        Enum.map(scalars, fn {k, v} -> "#{k} = #{encode_value(v)}" end)

      section = [header] ++ scalar_lines

      # Add a blank line before sections (unless we're at the start)
      acc =
        if acc != [] do
          acc ++ [""]
        else
          acc
        end

      acc
      |> Kernel.++(section)
      |> add_tables(nested_tables, full_key)
      |> add_array_tables(nested_array_tables, full_key)
    end)
  end

  defp add_array_tables(parts, [], _prefix), do: parts

  defp add_array_tables(parts, array_tables, prefix) do
    Enum.reduce(array_tables, parts, fn {key, items}, acc ->
      full_key = prefix ++ [key]
      header = "[[#{Enum.join(full_key, ".")}]]"

      Enum.reduce(items, acc, fn item, inner_acc ->
        {scalars, _nested_tables, _nested_array_tables} = partition_map(item)

        item_lines =
          Enum.map(scalars, fn {k, v} -> "#{k} = #{encode_value(v)}" end)

        section = ["", header] ++ item_lines
        inner_acc ++ section
      end)
    end)
  end

  @doc false
  @spec encode_value(term()) :: String.t()
  def encode_value(value) when is_binary(value), do: encode_string(value)
  def encode_value(value) when is_boolean(value), do: to_string(value)
  def encode_value(value) when is_integer(value), do: to_string(value)
  def encode_value(value) when is_float(value), do: to_string(value)
  def encode_value(value) when is_list(value), do: encode_array(value)

  def encode_value(value) when is_map(value) do
    inner =
      value
      |> sort_keys()
      |> Enum.map_join(", ", fn {k, v} -> "#{k} = #{encode_value(v)}" end)

    "{#{inner}}"
  end

  defp encode_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"#{escaped}\""
  end

  defp encode_array(list) do
    "[#{Enum.map_join(list, ", ", &encode_value/1)}]"
  end
end
