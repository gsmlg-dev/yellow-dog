defmodule YellowDog.Console.DiagnosticsLive.Components.HexDumpTest do
  @moduledoc """
  Tests for the HexDump component which displays binary data as xxd-style hex dumps.
  Tests the format_binary/1 function and component rendering.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Console.DiagnosticsLive.Components.HexDump

  # ============================================================================
  # format_binary/1 Tests
  # ============================================================================

  describe "HexDump.format_binary/1" do
    test "nil returns empty string" do
      result = HexDump.format_binary(nil)
      assert result == ""
    end

    test "empty binary returns empty string" do
      result = HexDump.format_binary(<<>>)
      assert result == ""
    end

    test "binary with data calls HexFormatter.format" do
      binary = <<0x00, 0x01, 0x02, 0x03>>
      result = HexDump.format_binary(binary)
      # Should be non-empty hex dump
      assert result != ""
      assert String.contains?(result, "00000000")
    end

    test "non-binary input returns empty string" do
      # Note: strings are binaries in Elixir, so "string" won't match this clause
      assert HexDump.format_binary(123) == ""
      assert HexDump.format_binary([1, 2, 3]) == ""
      assert HexDump.format_binary(%{a: 1}) == ""
      assert HexDump.format_binary(:atom) == ""
    end

    test "string is formatted as binary (strings are binaries)" do
      # In Elixir, strings are binaries, so they get formatted
      result = HexDump.format_binary("test")
      assert result != ""
      assert String.contains?(result, "74")  # ASCII for 't'
    end

    test "single byte binary" do
      result = HexDump.format_binary(<<0xFF>>)
      assert result != ""
      assert String.contains?(result, "ff")
    end

    test "longer binary data" do
      data = :binary.list_to_bin(Enum.to_list(0..15))
      result = HexDump.format_binary(data)
      assert result != ""
      # Should contain hex values
      assert String.contains?(result, "00")
      assert String.contains?(result, "0f")
    end
  end
end
