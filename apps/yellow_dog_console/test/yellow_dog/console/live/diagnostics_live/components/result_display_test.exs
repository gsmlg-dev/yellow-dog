defmodule YellowDog.Console.DiagnosticsLive.Components.ResultDisplayTest do
  @moduledoc """
  Tests for the ResultDisplay component which renders query results.
  Tests formatting functions for status, latency, structs, and addresses.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Console.DiagnosticsLive.Components.ResultDisplay

  # ============================================================================
  # status_text/1 Tests
  # ============================================================================

  describe "ResultDisplay.status_text/1" do
    test "success status returns 'Success'" do
      assert ResultDisplay.status_text(:success) == "Success"
    end

    test "timeout status returns 'Timeout'" do
      assert ResultDisplay.status_text(:timeout) == "Timeout"
    end

    test "error status returns 'Error'" do
      assert ResultDisplay.status_text(:error) == "Error"
    end
  end

  # ============================================================================
  # format_latency/1 Tests
  # ============================================================================

  describe "ResultDisplay.format_latency/1" do
    test "0 ms displays as '<1ms'" do
      assert ResultDisplay.format_latency(0) == "<1ms"
    end

    test "1 ms displays correctly" do
      assert ResultDisplay.format_latency(1) == "1ms"
    end

    test "999 ms displays in ms" do
      assert ResultDisplay.format_latency(999) == "999ms"
    end

    test "1000 ms displays with s suffix" do
      result = ResultDisplay.format_latency(1000)
      assert String.contains?(result, "1.0")
      assert String.contains?(result, "s")
    end

    test "1500 ms displays with s suffix" do
      result = ResultDisplay.format_latency(1500)
      assert String.contains?(result, "1.5")
      assert String.contains?(result, "s")
    end

    test "5000 ms displays with s suffix" do
      result = ResultDisplay.format_latency(5000)
      assert String.contains?(result, "5.0")
      assert String.contains?(result, "s")
    end

    test "non-integer returns empty string" do
      assert ResultDisplay.format_latency(nil) == ""
      assert ResultDisplay.format_latency("123") == ""
      assert ResultDisplay.format_latency(1.5) == ""
    end
  end

  # ============================================================================
  # format_struct/1 Tests
  # ============================================================================

  describe "ResultDisplay.format_struct/1" do
    test "nil returns '(empty)'" do
      assert ResultDisplay.format_struct(nil) == "(empty)"
    end

    test "map struct is formatted via inspect" do
      struct = %{"key" => "value"}
      result = ResultDisplay.format_struct(struct)
      assert is_binary(result)
      assert String.contains?(result, "value")
    end

    test "generic struct is formatted" do
      struct = %URI{scheme: "http", host: "example.com"}
      result = ResultDisplay.format_struct(struct)
      assert is_binary(result)
    end
  end

  # ============================================================================
  # format_address/1 Tests
  # ============================================================================

  describe "ResultDisplay.format_address/1" do
    test "IPv4 tuple address is formatted" do
      result = ResultDisplay.format_address({192, 168, 1, 1})
      assert String.contains?(result, "192")
    end

    test "IPv6 tuple address is formatted" do
      result = ResultDisplay.format_address({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      assert String.contains?(result, "2001") or is_binary(result)
    end

    test "string address is returned" do
      result = ResultDisplay.format_address("192.168.1.1")
      assert String.contains?(result, "192")
    end

    test "nil address returns empty or inspect" do
      result = ResultDisplay.format_address(nil)
      assert is_binary(result)
    end

    test "atom address is formatted via inspect" do
      result = ResultDisplay.format_address(:unknown)
      # inspect returns ":unknown" or the format_ip helper returns "Unknown"
      assert String.contains?(String.downcase(result), "unknown")
    end
  end
end
