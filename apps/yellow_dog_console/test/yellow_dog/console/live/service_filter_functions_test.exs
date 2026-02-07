defmodule YellowDog.Console.ServiceFilterFunctionsTest do
  @moduledoc """
  Unit tests for public filter functions in mDNS, DHCPv4, and DHCPv6 LiveViews.
  """
  use ExUnit.Case, async: true

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
end
