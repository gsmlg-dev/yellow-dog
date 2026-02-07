defmodule YellowDog.Console.CsvHelper do
  @moduledoc """
  Shared CSV utilities for LiveView pages that export data as CSV files.
  """

  @doc """
  Escapes a value for CSV output per RFC 4180.
  Wraps in double-quotes if the value contains commas, quotes, or newlines.
  """
  def csv_escape(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  def csv_escape(nil), do: ""
  def csv_escape(value), do: csv_escape(to_string(value))

  @doc "Joins a list of addresses with semicolons for CSV output."
  def format_addresses_for_csv(addresses) when is_list(addresses) do
    Enum.join(addresses, "; ")
  end

  def format_addresses_for_csv(_), do: ""

  @doc "Formats a TXT record map as semicolon-separated key=value pairs for CSV."
  def format_txt_for_csv(txt_map) when is_map(txt_map) do
    txt_map
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("; ")
  end

  def format_txt_for_csv(_), do: ""
end
