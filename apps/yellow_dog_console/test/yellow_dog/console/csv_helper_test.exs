defmodule YellowDog.Console.CsvHelperTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.CsvHelper

  describe "csv_escape/1" do
    test "returns plain string unchanged" do
      assert CsvHelper.csv_escape("hello") == "hello"
    end

    test "wraps value containing comma in double quotes" do
      assert CsvHelper.csv_escape("a,b") == "\"a,b\""
    end

    test "wraps value containing newline in double quotes" do
      assert CsvHelper.csv_escape("line1\nline2") == "\"line1\nline2\""
    end

    test "wraps value containing carriage return in double quotes" do
      assert CsvHelper.csv_escape("line1\rline2") == "\"line1\rline2\""
    end

    test "escapes double quotes by doubling them" do
      assert CsvHelper.csv_escape("say \"hello\"") == "\"say \"\"hello\"\"\""
    end

    test "handles value with both comma and quotes" do
      assert CsvHelper.csv_escape("a,\"b\"") == "\"a,\"\"b\"\"\""
    end

    test "returns empty string for nil" do
      assert CsvHelper.csv_escape(nil) == ""
    end

    test "converts non-binary to string then escapes" do
      assert CsvHelper.csv_escape(42) == "42"
      assert CsvHelper.csv_escape(:atom) == "atom"
    end

    test "returns empty string unchanged" do
      assert CsvHelper.csv_escape("") == ""
    end
  end

  describe "format_addresses_for_csv/1" do
    test "joins addresses with semicolons" do
      assert CsvHelper.format_addresses_for_csv(["10.0.0.1", "10.0.0.2"]) == "10.0.0.1; 10.0.0.2"
    end

    test "handles single address" do
      assert CsvHelper.format_addresses_for_csv(["10.0.0.1"]) == "10.0.0.1"
    end

    test "returns empty string for empty list" do
      assert CsvHelper.format_addresses_for_csv([]) == ""
    end

    test "returns empty string for nil" do
      assert CsvHelper.format_addresses_for_csv(nil) == ""
    end

    test "returns empty string for non-list" do
      assert CsvHelper.format_addresses_for_csv("not a list") == ""
    end
  end

  describe "format_txt_for_csv/1" do
    test "formats map as key=value pairs separated by semicolons" do
      result = CsvHelper.format_txt_for_csv(%{"path" => "/", "version" => "1.0"})
      # Map ordering is not guaranteed, so check both entries are present
      assert String.contains?(result, "path=/")
      assert String.contains?(result, "version=1.0")
      assert String.contains?(result, "; ")
    end

    test "handles single-entry map" do
      assert CsvHelper.format_txt_for_csv(%{"key" => "val"}) == "key=val"
    end

    test "handles empty map" do
      assert CsvHelper.format_txt_for_csv(%{}) == ""
    end

    test "returns empty string for nil" do
      assert CsvHelper.format_txt_for_csv(nil) == ""
    end

    test "returns empty string for non-map" do
      assert CsvHelper.format_txt_for_csv("not a map") == ""
    end
  end
end
