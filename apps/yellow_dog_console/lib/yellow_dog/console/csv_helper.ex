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
end
