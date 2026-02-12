defmodule YellowDog.Console.DiagnosticsLive.Components.QueryHistoryTest do
  @moduledoc """
  Tests for the QueryHistory component which displays previous diagnostic queries.
  Tests protocol-specific formatting for DNS, mDNS, DHCPv4, and DHCPv6.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Console.DiagnosticsLive.Components.QueryHistory

  # ============================================================================
  # format_entry_summary DNS Tests
  # ============================================================================

  describe "QueryHistory.format_entry_summary/2 for DNS" do
    test "formats with query_name and record_type" do
      entry = %{
        params: %{"query_name" => "example.com", "record_type" => "MX"}
      }

      result = QueryHistory.format_entry_summary(entry, :dns)
      assert result == "example.com (MX)"
    end

    test "handles missing query_name with ? default" do
      entry = %{params: %{"record_type" => "AAAA"}}
      result = QueryHistory.format_entry_summary(entry, :dns)
      assert result == "? (AAAA)"
    end

    test "handles missing record_type with A default" do
      entry = %{params: %{"query_name" => "test.local"}}
      result = QueryHistory.format_entry_summary(entry, :dns)
      assert result == "test.local (A)"
    end

    test "handles missing both with ? and A defaults" do
      entry = %{params: %{}}
      result = QueryHistory.format_entry_summary(entry, :dns)
      assert result == "? (A)"
    end

    test "uppercases record type" do
      entry = %{params: %{"query_name" => "example.com", "record_type" => "mx"}}
      result = QueryHistory.format_entry_summary(entry, :dns)
      assert result == "example.com (MX)"
    end
  end

  # ============================================================================
  # format_entry_summary mDNS Tests
  # ============================================================================

  describe "QueryHistory.format_entry_summary/2 for mDNS" do
    test "formats with service_type" do
      entry = %{params: %{"service_type" => "_ssh._tcp.local"}}
      result = QueryHistory.format_entry_summary(entry, :mdns)
      assert result == "_ssh._tcp.local"
    end

    test "handles missing service_type with ? default" do
      entry = %{params: %{}}
      result = QueryHistory.format_entry_summary(entry, :mdns)
      assert result == "?"
    end
  end

  # ============================================================================
  # format_entry_summary DHCPv4 Tests
  # ============================================================================

  describe "QueryHistory.format_entry_summary/2 for DHCPv4" do
    test "formats with message_type and client_mac (atom keys)" do
      entry = %{
        params: [message_type: :DHCPDISCOVER, client_mac: "AA:BB:CC:DD:EE:FF"]
      }

      result = QueryHistory.format_entry_summary(entry, :dhcpv4)
      assert String.starts_with?(result, "DHCPDISCOVER")
      assert String.contains?(result, "EE:FF")
    end

    test "formats with message_type and client_mac (string keys)" do
      entry = %{
        params: %{"message_type" => "DHCPREQUEST", "client_mac" => "112233445566"}
      }

      result = QueryHistory.format_entry_summary(entry, :dhcpv4)
      assert String.starts_with?(result, "DHCPREQUEST")
      assert String.contains?(result, "5566")
    end

    test "handles missing message_type with ? default" do
      entry = %{params: %{"client_mac" => "AABBCCDDEE00"}}
      result = QueryHistory.format_entry_summary(entry, :dhcpv4)
      assert String.contains?(result, "?")
    end

    test "handles missing client_mac without MAC suffix" do
      entry = %{params: %{"message_type" => "DHCPRELEASE"}}
      result = QueryHistory.format_entry_summary(entry, :dhcpv4)
      assert result == "DHCPRELEASE"
    end

    test "handles empty client_mac without suffix" do
      entry = %{params: %{"message_type" => "DHCPDECLINE", "client_mac" => ""}}
      result = QueryHistory.format_entry_summary(entry, :dhcpv4)
      assert result == "DHCPDECLINE"
    end

    test "extracts last 8 characters of long MAC address" do
      entry = %{params: [message_type: :DHCPACK, client_mac: "0123456789ABCDEF"]}
      result = QueryHistory.format_entry_summary(entry, :dhcpv4)
      assert String.contains?(result, "89ABCDEF")
    end
  end

  # ============================================================================
  # format_entry_summary DHCPv6 Tests
  # ============================================================================

  describe "QueryHistory.format_entry_summary/2 for DHCPv6" do
    test "formats with message_type" do
      entry = %{params: %{"message_type" => "REPLY"}}
      result = QueryHistory.format_entry_summary(entry, :dhcpv6)
      assert result == "REPLY"
    end

    test "handles missing message_type with ? default" do
      entry = %{params: %{}}
      result = QueryHistory.format_entry_summary(entry, :dhcpv6)
      assert result == "?"
    end

    test "uppercases message type" do
      entry = %{params: %{"message_type" => "request"}}
      result = QueryHistory.format_entry_summary(entry, :dhcpv6)
      assert result == "REQUEST"
    end
  end

  # ============================================================================
  # format_entry_summary Unknown Protocol Tests
  # ============================================================================

  describe "QueryHistory.format_entry_summary/2 for unknown protocol" do
    test "returns 'Query' for unknown protocol" do
      entry = %{params: %{"foo" => "bar"}}
      result = QueryHistory.format_entry_summary(entry, :unknown)
      assert result == "Query"
    end
  end

  # ============================================================================
  # format_latency/1 Tests
  # ============================================================================

  describe "QueryHistory.format_latency/1" do
    test "formats milliseconds under 1000 with ms suffix" do
      assert QueryHistory.format_latency(0) == "0ms"
      assert QueryHistory.format_latency(1) == "1ms"
      assert QueryHistory.format_latency(500) == "500ms"
      assert QueryHistory.format_latency(999) == "999ms"
    end

    test "formats seconds >= 1000 with s suffix" do
      assert QueryHistory.format_latency(1000) == "1.0s"
      assert QueryHistory.format_latency(1500) == "1.5s"
      assert QueryHistory.format_latency(5000) == "5.0s"
      assert QueryHistory.format_latency(10500) == "10.5s"
    end

    test "rounds to 1 decimal place for seconds" do
      assert QueryHistory.format_latency(1234) == "1.2s"
      assert QueryHistory.format_latency(1567) == "1.6s"
      assert QueryHistory.format_latency(1999) == "2.0s"
    end

    test "non-integer values return empty string" do
      assert QueryHistory.format_latency(nil) == ""
      assert QueryHistory.format_latency("500") == ""
      assert QueryHistory.format_latency(1.5) == ""
    end
  end
end
