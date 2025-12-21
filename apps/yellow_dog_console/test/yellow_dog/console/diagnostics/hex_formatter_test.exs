defmodule YellowDog.Console.Diagnostics.HexFormatterTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.Diagnostics.HexFormatter

  describe "format/1" do
    test "formats empty binary" do
      assert HexFormatter.format(<<>>) == ""
    end

    test "formats single byte" do
      result = HexFormatter.format(<<0x41>>)
      assert result =~ "00000000"
      assert result =~ "41"
      assert result =~ "A"
    end

    test "formats 16-byte row" do
      data = "ABCDEFGHIJKLMNOP"
      result = HexFormatter.format(data)
      # Should have offset, hex bytes, and ASCII
      assert result =~ "00000000"
      assert result =~ "41 42 43 44"
      assert result =~ "ABCDEFGHIJKLMNOP"
    end

    test "formats multiple rows" do
      data = String.duplicate("X", 32)
      result = HexFormatter.format(data)
      lines = String.split(result, "\n", trim: true)
      assert length(lines) == 2
      assert Enum.at(lines, 0) =~ "00000000"
      assert Enum.at(lines, 1) =~ "00000010"
    end

    test "formats partial row with padding" do
      data = "ABC"
      result = HexFormatter.format(data)
      # Should have offset, 3 hex bytes, padding, and ASCII
      assert result =~ "00000000"
      assert result =~ "41 42 43"
      assert result =~ "ABC"
    end

    test "replaces non-printable characters with dots" do
      data = <<0x00, 0x01, 0x41, 0x7F>>
      result = HexFormatter.format(data)
      # Non-printable chars should be dots, 'A' should remain
      assert result =~ ".."
      assert result =~ "A"
    end

    test "handles binary with null bytes" do
      data = <<0, 0, 0, 0>>
      result = HexFormatter.format(data)
      assert result =~ "00 00 00 00"
      assert result =~ "...."
    end

    test "formats DNS-like binary correctly" do
      # Typical DNS header snippet
      data = <<0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00>>
      result = HexFormatter.format(data)
      assert result =~ "ab cd 01 00 00 01 00 00"
    end
  end

  describe "format_inline/1" do
    test "formats empty binary" do
      assert HexFormatter.format_inline(<<>>) == ""
    end

    test "formats single byte" do
      assert HexFormatter.format_inline(<<0x41>>) == "41"
    end

    test "formats multiple bytes with spaces" do
      assert HexFormatter.format_inline(<<0x41, 0x42, 0x43>>) == "41 42 43"
    end

    test "formats binary with lowercase hex" do
      assert HexFormatter.format_inline(<<0xAB, 0xCD, 0xEF>>) == "ab cd ef"
    end

    test "formats all zeros" do
      assert HexFormatter.format_inline(<<0, 0, 0>>) == "00 00 00"
    end
  end
end
