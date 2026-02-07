defmodule YellowDog.Console.CsvHelperTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.CsvHelper

  describe "csv_escape/1" do
    test "returns plain string unchanged" do
      assert CsvHelper.csv_escape("hello") == "hello"
    end

    test "returns empty string unchanged" do
      assert CsvHelper.csv_escape("") == ""
    end

    test "wraps value containing comma in quotes" do
      assert CsvHelper.csv_escape("foo,bar") == "\"foo,bar\""
    end

    test "wraps value containing newline in quotes" do
      assert CsvHelper.csv_escape("foo\nbar") == "\"foo\nbar\""
    end

    test "wraps value containing carriage return in quotes" do
      assert CsvHelper.csv_escape("foo\rbar") == "\"foo\rbar\""
    end

    test "wraps value containing double quote and escapes quotes" do
      assert CsvHelper.csv_escape("foo\"bar") == "\"foo\"\"bar\""
    end

    test "escapes multiple double quotes" do
      assert CsvHelper.csv_escape("a\"b\"c") == "\"a\"\"b\"\"c\""
    end

    test "handles value with both comma and quote" do
      assert CsvHelper.csv_escape("a,b\"c") == "\"a,b\"\"c\""
    end

    test "returns empty string for nil" do
      assert CsvHelper.csv_escape(nil) == ""
    end

    test "converts integer to string" do
      assert CsvHelper.csv_escape(42) == "42"
    end

    test "converts atom to string" do
      assert CsvHelper.csv_escape(:active) == "active"
    end

    test "converts float to string" do
      assert CsvHelper.csv_escape(3.14) == "3.14"
    end
  end

  describe "format_addresses_for_csv/1" do
    test "joins addresses with semicolons" do
      assert CsvHelper.format_addresses_for_csv(["10.0.0.1", "10.0.0.2"]) == "10.0.0.1; 10.0.0.2"
    end

    test "returns single address as-is" do
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

    test "returns empty string for integer" do
      assert CsvHelper.format_addresses_for_csv(42) == ""
    end
  end

  describe "format_txt_for_csv/1" do
    test "formats map as key=value pairs" do
      result = CsvHelper.format_txt_for_csv(%{"path" => "/", "version" => "1.0"})
      assert result =~ "path=/"
      assert result =~ "version=1.0"
      assert result =~ "; "
    end

    test "formats single entry map" do
      assert CsvHelper.format_txt_for_csv(%{"key" => "value"}) == "key=value"
    end

    test "returns empty string for empty map" do
      assert CsvHelper.format_txt_for_csv(%{}) == ""
    end

    test "returns empty string for nil" do
      assert CsvHelper.format_txt_for_csv(nil) == ""
    end

    test "returns empty string for non-map" do
      assert CsvHelper.format_txt_for_csv("not a map") == ""
    end

    test "returns empty string for list" do
      assert CsvHelper.format_txt_for_csv([1, 2, 3]) == ""
    end
  end
end
