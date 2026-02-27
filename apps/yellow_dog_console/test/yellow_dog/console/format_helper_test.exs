defmodule YellowDog.Console.FormatHelperTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.FormatHelper

  describe "format_mac/1" do
    test "formats 6-byte binary as colon-separated uppercase hex" do
      assert FormatHelper.format_mac(<<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>) ==
               "AA:BB:CC:DD:EE:FF"
    end

    test "formats zero MAC" do
      assert FormatHelper.format_mac(<<0, 0, 0, 0, 0, 0>>) == "00:00:00:00:00:00"
    end

    test "returns Unknown for non-binary" do
      assert FormatHelper.format_mac(nil) == "Unknown"
      assert FormatHelper.format_mac(123) == "Unknown"
    end

    test "returns Unknown for short binary" do
      assert FormatHelper.format_mac(<<1, 2, 3>>) == "Unknown"
    end
  end

  describe "format_ip/1" do
    test "formats IPv4 tuple" do
      assert FormatHelper.format_ip({192, 168, 1, 1}) == "192.168.1.1"
    end

    test "formats IPv6 tuple as hex" do
      result = FormatHelper.format_ip({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      assert result =~ "2001"
      assert result =~ ":"
    end

    test "passes through binary strings" do
      assert FormatHelper.format_ip("10.0.0.1") == "10.0.0.1"
    end

    test "returns nil for nil" do
      assert FormatHelper.format_ip(nil) == nil
    end

    test "returns Unknown for other types" do
      assert FormatHelper.format_ip(:invalid) == "Unknown"
    end
  end

  describe "format_duid/1" do
    test "formats binary DUID as colon-separated uppercase hex" do
      assert FormatHelper.format_duid(<<0x00, 0x01, 0x00, 0x01>>) == "00:01:00:01"
    end

    test "returns Unknown for non-binary" do
      assert FormatHelper.format_duid(nil) == "Unknown"
      assert FormatHelper.format_duid(123) == "Unknown"
    end
  end

  describe "format_ipv6/1" do
    test "formats 8-tuple as lowercase colon-separated hex" do
      result = FormatHelper.format_ipv6({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      assert result == "2001:db8:0:0:0:0:0:1"
    end

    test "returns Unknown for non-tuple" do
      assert FormatHelper.format_ipv6(nil) == "Unknown"
      assert FormatHelper.format_ipv6("::1") == "Unknown"
    end
  end

  describe "format_expiration/1" do
    test "formats unix timestamp as datetime string" do
      # 2024-01-01 00:00:00 UTC
      result = FormatHelper.format_expiration(1_704_067_200)
      assert result =~ "2024"
      assert result =~ ":"
    end

    test "returns N/A for non-integer" do
      assert FormatHelper.format_expiration(nil) == "N/A"
      assert FormatHelper.format_expiration("invalid") == "N/A"
    end
  end

  describe "format_time_remaining/1" do
    test "returns Expired for past timestamps" do
      past = System.system_time(:second) - 100
      assert FormatHelper.format_time_remaining(past) == "Expired"
    end

    test "returns minutes for near-future timestamps" do
      future = System.system_time(:second) + 1800
      assert FormatHelper.format_time_remaining(future) =~ "m remaining"
    end

    test "returns N/A for non-integer" do
      assert FormatHelper.format_time_remaining(nil) == "N/A"
    end
  end

  describe "expiration_color/1" do
    test "returns text-error for expired" do
      past = System.system_time(:second) - 100
      assert FormatHelper.expiration_color(past) == "text-error"
    end

    test "returns text-warning for soon-to-expire" do
      soon = System.system_time(:second) + 5400
      assert FormatHelper.expiration_color(soon) == "text-warning"
    end

    test "returns default for far-future" do
      future = System.system_time(:second) + 86400
      assert FormatHelper.expiration_color(future) == "text-base-content/50"
    end

    test "returns default for non-integer" do
      assert FormatHelper.expiration_color(nil) == "text-base-content/50"
    end
  end

  describe "format_prefix/1" do
    test "formats prefix tuple with length" do
      result = FormatHelper.format_prefix({{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 32})
      assert result =~ "2001:db8:"
      assert result =~ "/32"
    end

    test "returns Unknown for invalid input" do
      assert FormatHelper.format_prefix(nil) == "Unknown"
    end
  end

  describe "format_time/1" do
    test "formats DateTime as HH:MM:SS" do
      dt = ~U[2024-06-15 14:30:45Z]
      assert FormatHelper.format_time(dt) == "14:30:45"
    end

    test "formats midnight correctly" do
      dt = ~U[2024-01-01 00:00:00Z]
      assert FormatHelper.format_time(dt) == "00:00:00"
    end

    test "returns empty string for nil" do
      assert FormatHelper.format_time(nil) == ""
    end

    test "formats unix timestamp as HH:MM:SS" do
      # 12345 seconds from epoch = 03:25:45 UTC
      assert FormatHelper.format_time(12345) == "03:25:45"
    end

    test "returns empty string for non-DateTime and non-integer" do
      assert FormatHelper.format_time("14:30:45") == ""
    end
  end

  describe "format_time_ms/1" do
    test "formats DateTime with milliseconds" do
      dt = ~U[2024-06-15 14:30:45.123456Z]
      assert FormatHelper.format_time_ms(dt) == "14:30:45.123"
    end

    test "pads milliseconds with leading zeros" do
      dt = ~U[2024-06-15 14:30:45.005000Z]
      assert FormatHelper.format_time_ms(dt) == "14:30:45.005"
    end

    test "formats zero microseconds as .000" do
      dt = ~U[2024-06-15 14:30:45.000000Z]
      assert FormatHelper.format_time_ms(dt) == "14:30:45.000"
    end

    test "returns placeholder for nil" do
      assert FormatHelper.format_time_ms(nil) == "--:--:--.---"
    end

    test "formats unix nanosecond timestamp" do
      # 1718458245_123_456_789 ns from epoch
      ts = 1_718_458_245_123_456_789
      result = FormatHelper.format_time_ms(ts)
      assert result =~ ~r/^\d{2}:\d{2}:\d{2}\.\d{3}$/
    end

    test "returns placeholder for non-DateTime" do
      assert FormatHelper.format_time_ms("14:30:45") == "--:--:--.---"
    end
  end

  describe "format_time_ago/1" do
    test "formats seconds ago" do
      ts = System.system_time(:second) - 30
      assert FormatHelper.format_time_ago(ts) == "30s ago"
    end

    test "formats minutes ago" do
      ts = System.system_time(:second) - 120
      assert FormatHelper.format_time_ago(ts) == "2m ago"
    end

    test "formats hours ago" do
      ts = System.system_time(:second) - 7200
      assert FormatHelper.format_time_ago(ts) == "2h ago"
    end

    test "formats days ago" do
      ts = System.system_time(:second) - 172_800
      assert FormatHelper.format_time_ago(ts) == "2d ago"
    end

    test "returns Unknown for nil" do
      assert FormatHelper.format_time_ago(nil) == "Unknown"
    end
  end

  describe "format_uptime/1" do
    test "formats seconds only" do
      assert FormatHelper.format_uptime(45) == "45s"
    end

    test "formats minutes and seconds" do
      assert FormatHelper.format_uptime(125) == "2m 5s"
    end

    test "formats hours and minutes" do
      assert FormatHelper.format_uptime(3725) == "1h 2m"
    end

    test "formats large hours" do
      assert FormatHelper.format_uptime(36000) == "10h 0m"
    end

    test "formats zero" do
      assert FormatHelper.format_uptime(0) == "0s"
    end

    test "truncates floats" do
      assert FormatHelper.format_uptime(65.7) == "1m 5s"
    end

    test "returns 0s for non-number" do
      assert FormatHelper.format_uptime(nil) == "0s"
      assert FormatHelper.format_uptime("1h") == "0s"
    end
  end

  describe "format_bytes/1" do
    test "formats nil as N/A" do
      assert FormatHelper.format_bytes(nil) == "N/A"
    end

    test "formats bytes" do
      assert FormatHelper.format_bytes(500) == "500B"
    end

    test "formats kilobytes" do
      assert FormatHelper.format_bytes(2048) == "2.0KB"
    end

    test "formats megabytes" do
      assert FormatHelper.format_bytes(1_572_864) == "1.5MB"
    end

    test "formats gigabytes" do
      assert FormatHelper.format_bytes(2_147_483_648) == "2.0GB"
    end

    test "formats zero" do
      assert FormatHelper.format_bytes(0) == "0B"
    end

    test "returns N/A for non-integer" do
      assert FormatHelper.format_bytes("1024") == "N/A"
      assert FormatHelper.format_bytes(1.5) == "N/A"
    end
  end

  describe "format_duration/1" do
    test "formats seconds" do
      assert FormatHelper.format_duration(30) == "30s"
    end

    test "formats minutes" do
      assert FormatHelper.format_duration(300) == "5m"
    end

    test "formats hours" do
      assert FormatHelper.format_duration(7200) == "2h"
    end

    test "formats days" do
      assert FormatHelper.format_duration(172_800) == "2d"
    end

    test "returns N/A for non-integer" do
      assert FormatHelper.format_duration(nil) == "N/A"
    end
  end

  describe "format_expires/1" do
    test "returns Expired for past timestamps" do
      past = System.system_time(:second) - 100
      assert FormatHelper.format_expires(past) == "Expired"
    end

    test "returns compact time for future timestamps" do
      future = System.system_time(:second) + 7200
      assert FormatHelper.format_expires(future) == "2h"
    end

    test "returns N/A for non-integer" do
      assert FormatHelper.format_expires(nil) == "N/A"
    end
  end

  describe "format_ia_type/1" do
    test "formats known IA types" do
      assert FormatHelper.format_ia_type(:ia_na) == "IA_NA"
      assert FormatHelper.format_ia_type(:ia_ta) == "IA_TA"
      assert FormatHelper.format_ia_type(:ia_pd) == "IA_PD"
    end

    test "falls back to string conversion" do
      assert FormatHelper.format_ia_type(:unknown) == "unknown"
    end
  end

  describe "parse_mac_string/1" do
    test "parses colon-separated MAC string" do
      assert FormatHelper.parse_mac_string("AA:BB:CC:DD:EE:FF") ==
               <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
    end

    test "returns zero MAC for invalid input" do
      assert FormatHelper.parse_mac_string("invalid") == <<0, 0, 0, 0, 0, 0>>
    end
  end

  describe "parse_duid_string/1" do
    test "parses colon-separated hex DUID" do
      assert FormatHelper.parse_duid_string("00:01:00:01") == <<0, 1, 0, 1>>
    end

    test "handles invalid hex bytes gracefully" do
      assert FormatHelper.parse_duid_string("ZZ:01") == <<0, 1>>
    end
  end

  describe "filtered_countries/2" do
    @countries [
      %{code: "US", name: "United States"},
      %{code: "GB", name: "United Kingdom"},
      %{code: "DE", name: "Germany"},
      %{code: "JP", name: "Japan"}
    ]

    test "returns all countries for empty search" do
      assert FormatHelper.filtered_countries(@countries, "") == @countries
    end

    test "filters by country name (case-insensitive)" do
      result = FormatHelper.filtered_countries(@countries, "united")
      assert length(result) == 2
      assert Enum.all?(result, fn c -> c.name =~ "United" end)
    end

    test "filters by country code" do
      result = FormatHelper.filtered_countries(@countries, "JP")
      assert length(result) == 1
      assert hd(result).code == "JP"
    end

    test "returns empty list for no matches" do
      assert FormatHelper.filtered_countries(@countries, "xyz") == []
    end
  end

  describe "filter_by_state/2" do
    @leases [
      %{state: :bound, ip: "10.0.0.1"},
      %{state: :offered, ip: "10.0.0.2"},
      %{state: :expired, ip: "10.0.0.3"},
      %{state: :bound, ip: "10.0.0.4"}
    ]

    test "returns all items for 'all' filter" do
      assert FormatHelper.filter_by_state(@leases, "all") == @leases
    end

    test "filters by state using to_string comparison" do
      result = FormatHelper.filter_by_state(@leases, "bound")
      assert length(result) == 2
      assert Enum.all?(result, fn l -> l.state == :bound end)
    end

    test "returns empty list when no items match" do
      assert FormatHelper.filter_by_state(@leases, "released") == []
    end

    test "handles empty list" do
      assert FormatHelper.filter_by_state([], "bound") == []
    end
  end

  describe "filter_by_pool/2" do
    @pool_leases [
      %{pool_name: "office", ip: "10.0.0.1"},
      %{pool_name: "guest", ip: "10.0.0.2"},
      %{pool_name: "office", ip: "10.0.0.3"}
    ]

    test "returns all items for 'all' filter" do
      assert FormatHelper.filter_by_pool(@pool_leases, "all") == @pool_leases
    end

    test "filters by pool_name" do
      result = FormatHelper.filter_by_pool(@pool_leases, "office")
      assert length(result) == 2
      assert Enum.all?(result, fn l -> l.pool_name == "office" end)
    end

    test "returns empty list when no items match" do
      assert FormatHelper.filter_by_pool(@pool_leases, "server") == []
    end

    test "handles empty list" do
      assert FormatHelper.filter_by_pool([], "office") == []
    end
  end

  describe "filtered_pools/2" do
    @pools [
      %{name: "office", network: "192.168.1.0/24", range_start: {192, 168, 1, 100}},
      %{name: "guest", network: "10.0.0.0/24", range_start: {10, 0, 0, 50}},
      %{name: "server", network: "172.16.0.0/16", range_start: {172, 16, 0, 10}}
    ]

    test "returns all pools for empty filter" do
      assert FormatHelper.filtered_pools(@pools, "") == @pools
    end

    test "filters by pool name" do
      result = FormatHelper.filtered_pools(@pools, "office")
      assert length(result) == 1
      assert hd(result).name == "office"
    end

    test "filters by network" do
      result = FormatHelper.filtered_pools(@pools, "172.16")
      assert length(result) == 1
      assert hd(result).name == "server"
    end

    test "filters by range start IP" do
      result = FormatHelper.filtered_pools(@pools, "10.0.0")
      assert length(result) == 1
      assert hd(result).name == "guest"
    end

    test "filter is case-insensitive" do
      result = FormatHelper.filtered_pools(@pools, "GUEST")
      assert length(result) == 1
    end

    test "returns empty list for no matches" do
      assert FormatHelper.filtered_pools(@pools, "xyz") == []
    end

    test "handles empty pools list" do
      assert FormatHelper.filtered_pools([], "test") == []
    end
  end

  describe "format_dns_servers/1" do
    test "returns empty list for nil" do
      assert FormatHelper.format_dns_servers(nil) == []
    end

    test "formats IPv4 tuple servers" do
      result = FormatHelper.format_dns_servers([{8, 8, 8, 8}, {8, 8, 4, 4}])
      assert result == ["8.8.8.8", "8.8.4.4"]
    end

    test "passes through string servers" do
      result = FormatHelper.format_dns_servers(["8.8.8.8", "1.1.1.1"])
      assert result == ["8.8.8.8", "1.1.1.1"]
    end

    test "handles empty list" do
      assert FormatHelper.format_dns_servers([]) == []
    end
  end
end
