defmodule YellowDog.Console.StringHelper do
  @moduledoc """
  Shared string parsing and manipulation helpers.

  Provides common operations for parsing user input from forms,
  particularly for handling multi-line or comma-separated values.
  """

  @doc """
  Splits a string by a separator and returns a list of non-empty trimmed values.

  This is a common pattern when parsing textarea input with one value per line,
  or comma-separated lists. Combines:
  - `String.split/2` with `trim: true`
  - `Enum.map(&String.trim/1)` to trim each element
  - `Enum.reject(&(&1 == ""))` to remove empty strings

  ## Examples

      iex> StringHelper.split_and_trim("a\\nb\\n\\nc", "\\n")
      ["a", "b", "c"]

      iex> StringHelper.split_and_trim("  one,  two,  three  ", ",")
      ["one", "two", "three"]

      iex> StringHelper.split_and_trim("", "\\n")
      []

      iex> StringHelper.split_and_trim("one", "\\n")
      ["one"]

  """
  @spec split_and_trim(String.t(), String.t() | Regex.t()) :: [String.t()]
  def split_and_trim(string, separator) when is_binary(string) do
    string
    |> String.split(separator, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def split_and_trim(_, _), do: []

  @doc """
  Case-insensitive substring check.

  Returns `true` if `haystack` contains `needle` (both downcased).
  The `needle` should already be downcased by the caller for efficiency
  when checking multiple fields against the same search term.

  ## Examples

      iex> StringHelper.downcase_contains?("Hello World", "hello")
      true

      iex> StringHelper.downcase_contains?("DNS Server", "ftp")
      false

      iex> StringHelper.downcase_contains?("", "test")
      false

  """
  @spec downcase_contains?(String.t(), String.t()) :: boolean()
  def downcase_contains?(haystack, needle) when is_binary(haystack) and is_binary(needle) do
    String.contains?(String.downcase(haystack), needle)
  end

  def downcase_contains?(_, _), do: false
end
