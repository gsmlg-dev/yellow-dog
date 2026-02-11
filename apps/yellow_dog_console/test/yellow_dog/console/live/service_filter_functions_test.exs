defmodule YellowDog.Console.ServiceFilterFunctionsTest do
  @moduledoc """
  Unit tests for public filter functions in mDNS, DHCPv4, and DHCPv6 LiveViews.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Console.Dhcpv4Live.ActivityLive, as: Dhcpv4Activity
  alias YellowDog.Console.Dhcpv6Live.ActivityLive, as: Dhcpv6Activity
  alias YellowDog.Console.MdnsLive.MonitorLive
  alias YellowDog.Console.FormatHelper

  # ============================================================================
  # MonitorLive.filtered_queries/2
  # ============================================================================

  describe "MonitorLive.filtered_queries/2" do
    @queries [
      %{name: "_http._tcp.local", type: :ptr, source_ip: {192, 168, 1, 100}},
      %{name: "_ssh._tcp.local", type: :ptr, source_ip: {10, 0, 0, 1}},
      %{name: "_printer._tcp.local", type: :srv, source_ip: {192, 168, 1, 200}}
    ]

    test "returns all queries with empty search" do
      assert length(MonitorLive.filtered_queries(@queries, "")) == 3
    end

    test "filters by name substring" do
      result = MonitorLive.filtered_queries(@queries, "http")
      assert length(result) == 1
      assert hd(result).name == "_http._tcp.local"
    end

    test "filters by type" do
      result = MonitorLive.filtered_queries(@queries, "srv")
      assert length(result) == 1
      assert hd(result).type == :srv
    end

    test "filters by source IP" do
      result = MonitorLive.filtered_queries(@queries, "192.168")
      assert length(result) == 2
    end

    test "case-insensitive filtering" do
      result = MonitorLive.filtered_queries(@queries, "HTTP")
      assert length(result) == 1
    end

    test "returns empty for non-matching search" do
      assert MonitorLive.filtered_queries(@queries, "nonexistent") == []
    end

    test "handles empty queries list" do
      assert MonitorLive.filtered_queries([], "test") == []
    end
  end

  # ============================================================================
  # FormatHelper.filtered_pools/2 (DHCPv4 pools)
  # ============================================================================

  describe "FormatHelper.filtered_pools/2 (IPv4)" do
    @v4pools [
      %{name: "office-pool", network: "192.168.1.0/24", range_start: {192, 168, 1, 100}},
      %{name: "guest-pool", network: "10.0.0.0/24", range_start: {10, 0, 0, 50}}
    ]

    test "returns all pools with empty filter" do
      assert length(FormatHelper.filtered_pools(@v4pools, "")) == 2
    end

    test "filters by name" do
      result = FormatHelper.filtered_pools(@v4pools, "office")
      assert length(result) == 1
      assert hd(result).name == "office-pool"
    end

    test "filters by network" do
      result = FormatHelper.filtered_pools(@v4pools, "10.0.0")
      assert length(result) == 1
      assert hd(result).name == "guest-pool"
    end

    test "case-insensitive filtering" do
      result = FormatHelper.filtered_pools(@v4pools, "OFFICE")
      assert length(result) == 1
    end

    test "returns empty for non-matching filter" do
      assert FormatHelper.filtered_pools(@v4pools, "nope") == []
    end

    test "handles empty pools list" do
      assert FormatHelper.filtered_pools([], "test") == []
    end
  end

  # ============================================================================
  # FormatHelper.filtered_pools/2 (DHCPv6 pools)
  # ============================================================================

  describe "FormatHelper.filtered_pools/2 (IPv6)" do
    @v6pools [
      %{
        name: "v6-office",
        network: "2001:db8::/32",
        range_start: {8193, 3512, 0, 0, 0, 0, 0, 1}
      },
      %{
        name: "v6-guest",
        network: "fd00::/64",
        range_start: {64768, 0, 0, 0, 0, 0, 0, 1}
      }
    ]

    test "returns all pools with empty filter" do
      assert length(FormatHelper.filtered_pools(@v6pools, "")) == 2
    end

    test "filters by name" do
      result = FormatHelper.filtered_pools(@v6pools, "office")
      assert length(result) == 1
      assert hd(result).name == "v6-office"
    end

    test "filters by network" do
      result = FormatHelper.filtered_pools(@v6pools, "2001")
      assert length(result) == 1
      assert hd(result).name == "v6-office"
    end

    test "returns empty for non-matching filter" do
      assert FormatHelper.filtered_pools(@v6pools, "nope") == []
    end

    test "handles empty pools list" do
      assert FormatHelper.filtered_pools([], "test") == []
    end
  end

  # ============================================================================
  # Dhcpv4Activity.filtered_entries/3
  # ============================================================================

  describe "Dhcpv4Activity.filtered_entries/3" do
    @v4_entries [
      %{type: :discover, client_mac: "AA:BB:CC:DD:EE:01", client_ip: "192.168.1.10", details: "DISCOVER from office"},
      %{type: :ack, client_mac: "AA:BB:CC:DD:EE:02", client_ip: "10.0.0.5", details: "ACK for guest"},
      %{type: :nak, client_mac: "AA:BB:CC:DD:EE:03", client_ip: nil, details: "Pool exhausted"},
      %{type: :decline, client_mac: nil, client_ip: nil, details: "Client declined"}
    ]

    test "returns all entries with empty search and 'all' filter" do
      assert length(Dhcpv4Activity.filtered_entries(@v4_entries, "", "all")) == 4
    end

    test "filters by type" do
      result = Dhcpv4Activity.filtered_entries(@v4_entries, "", "discover")
      assert length(result) == 1
      assert hd(result).type == :discover
    end

    test "error filter includes nak, decline, and other error types" do
      result = Dhcpv4Activity.filtered_entries(@v4_entries, "", "error")
      assert length(result) == 2
      assert Enum.all?(result, fn e -> e.type in [:nak, :decline] end)
    end

    test "search filters by MAC address" do
      result = Dhcpv4Activity.filtered_entries(@v4_entries, "EE:01", "all")
      assert length(result) == 1
      assert hd(result).client_mac == "AA:BB:CC:DD:EE:01"
    end

    test "search filters by IP address" do
      result = Dhcpv4Activity.filtered_entries(@v4_entries, "10.0.0", "all")
      assert length(result) == 1
      assert hd(result).client_ip == "10.0.0.5"
    end

    test "search filters by details" do
      result = Dhcpv4Activity.filtered_entries(@v4_entries, "office", "all")
      assert length(result) == 1
    end

    test "search is case-insensitive" do
      result = Dhcpv4Activity.filtered_entries(@v4_entries, "OFFICE", "all")
      assert length(result) == 1
    end

    test "handles nil fields in entries" do
      result = Dhcpv4Activity.filtered_entries(@v4_entries, "nonexistent", "all")
      assert result == []
    end

    test "handles empty entries list" do
      assert Dhcpv4Activity.filtered_entries([], "test", "all") == []
    end

    test "invalid type filter falls back to showing all" do
      result = Dhcpv4Activity.filtered_entries(@v4_entries, "", "invalid_xyz")
      assert length(result) == 4
    end
  end

  # ============================================================================
  # Dhcpv6Activity.filtered_entries/3
  # ============================================================================

  describe "Dhcpv6Activity.filtered_entries/3" do
    @v6_entries [
      %{type: :solicit, client_duid: "00:01:00:01:AA:BB", client_ip: "2001:db8::1", details: "SOLICIT"},
      %{type: :reply, client_duid: "00:01:00:01:CC:DD", client_ip: "fd00::5", details: "REPLY granted"},
      %{type: :decline, client_duid: nil, client_ip: nil, details: "Client declined"}
    ]

    test "returns all entries with empty search and 'all' filter" do
      assert length(Dhcpv6Activity.filtered_entries(@v6_entries, "", "all")) == 3
    end

    test "filters by type" do
      result = Dhcpv6Activity.filtered_entries(@v6_entries, "", "solicit")
      assert length(result) == 1
      assert hd(result).type == :solicit
    end

    test "search filters by DUID" do
      result = Dhcpv6Activity.filtered_entries(@v6_entries, "AA:BB", "all")
      assert length(result) == 1
    end

    test "search filters by IP" do
      result = Dhcpv6Activity.filtered_entries(@v6_entries, "2001:db8", "all")
      assert length(result) == 1
    end

    test "search is case-insensitive" do
      result = Dhcpv6Activity.filtered_entries(@v6_entries, "solicit", "all")
      assert length(result) == 1
    end

    test "handles empty entries list" do
      assert Dhcpv6Activity.filtered_entries([], "test", "all") == []
    end
  end
end
