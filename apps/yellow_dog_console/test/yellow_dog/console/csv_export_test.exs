defmodule YellowDog.Console.CsvExportTest do
  @moduledoc """
  Unit tests for CSV export functionality across all console pages.

  Tests proper CSV escaping, special character handling, and data formatting
  for DHCPv4/v6 leases, mDNS services/discovery, and DNS ACLs.
  """
  use ExUnit.Case, async: true

  import YellowDog.Console.CsvHelper

  describe "CsvHelper.csv_escape/1" do
    test "escapes commas in values" do
      assert csv_escape("value,with,commas") == "\"value,with,commas\""
    end

    test "escapes double quotes in values" do
      assert csv_escape("value\"with\"quotes") == "\"value\"\"with\"\"quotes\""
    end

    test "escapes newlines in values" do
      assert csv_escape("value\nwith\nnewlines") == "\"value\nwith\nnewlines\""
    end

    test "escapes carriage returns" do
      assert csv_escape("value\rwith\rreturns") == "\"value\rwith\rreturns\""
    end

    test "escapes combined special characters" do
      assert csv_escape("value,with\"special\nchars") == "\"value,with\"\"special\nchars\""
    end

    test "does not escape simple values" do
      assert csv_escape("simple_value") == "simple_value"
    end

    test "handles empty strings" do
      assert csv_escape("") == ""
    end

    test "handles nil" do
      assert csv_escape(nil) == ""
    end

    test "converts non-binary values to string" do
      assert csv_escape(42) == "42"
      assert csv_escape(:atom) == "atom"
    end
  end

  describe "DHCPv4 lease CSV format" do
    test "builds valid CSV with proper headers" do
      leases = [
        %{
          mac_address: {0x00, 0x11, 0x22, 0x33, 0x44, 0x55},
          ip_address: {192, 168, 1, 100},
          hostname: "test-host",
          state: :active,
          pool_name: "default",
          allocated_at: 1_735_689_600,
          expires_at: 1_735_776_000
        }
      ]

      csv = build_dhcpv4_csv(leases)

      assert String.contains?(csv, "MAC Address,IP Address,Hostname")
      assert String.contains?(csv, "00:11:22:33:44:55")
      assert String.contains?(csv, "192.168.1.100")
      assert String.contains?(csv, "test-host")
      assert String.contains?(csv, "active")
      assert String.contains?(csv, "default")
    end

    test "handles special characters in hostname" do
      leases = [
        %{
          mac_address: {0x00, 0x11, 0x22, 0x33, 0x44, 0x55},
          ip_address: {192, 168, 1, 100},
          hostname: "host,with\"special\nchars",
          state: :active,
          pool_name: "default",
          allocated_at: 1_735_689_600,
          expires_at: 1_735_776_000
        }
      ]

      csv = build_dhcpv4_csv(leases)

      # Should be properly escaped
      assert String.contains?(csv, "\"host,with\"\"special\nchars\"")
    end

    test "handles missing optional fields" do
      leases = [
        %{
          mac_address: {0x00, 0x11, 0x22, 0x33, 0x44, 0x55},
          ip_address: {192, 168, 1, 100},
          hostname: nil,
          state: :active,
          pool_name: "default",
          allocated_at: 1_735_689_600,
          expires_at: 1_735_776_000
        }
      ]

      csv = build_dhcpv4_csv(leases)

      # Should handle nil hostname gracefully
      assert csv =~ ~r/192\.168\.1\.100,[^,]*,active/
    end
  end

  describe "DHCPv6 lease CSV format" do
    test "builds valid CSV with IPv6 addresses" do
      leases = [
        %{
          duid: <<0x00, 0x01, 0x02, 0x03>>,
          iaid: 12345,
          ia_type: :ia_na,
          ipv6_address: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
          state: :active,
          pool_name: "ipv6-pool",
          preferred_lifetime: 3600,
          valid_lifetime: 7200,
          allocated_at: 1_735_689_600
        }
      ]

      csv = build_dhcpv6_csv(leases)

      assert String.contains?(csv, "DUID,IAID,IA Type")
      assert String.contains?(csv, "00:01:02:03")
      assert String.contains?(csv, "12345")
      assert String.contains?(csv, "ia_na")
      # IPv6 formatting doesn't compress zeros
      assert String.contains?(csv, "2001:db8:0:0:0:0:0:1") or
               String.contains?(csv, "2001:db8::1")
    end

    test "formats prefix delegation correctly" do
      leases = [
        %{
          duid: <<0x00, 0x01, 0x02, 0x03>>,
          iaid: 12345,
          ia_type: :ia_pd,
          prefix: {0x2001, 0x0DB8, 0x1234, 0, 0, 0, 0, 0},
          prefix_length: 56,
          state: :active,
          pool_name: "pd-pool",
          preferred_lifetime: 3600,
          valid_lifetime: 7200,
          allocated_at: 1_735_689_600
        }
      ]

      csv = build_dhcpv6_csv(leases)

      assert String.contains?(csv, "2001:db8:1234::/56") or
               String.contains?(csv, "2001:db8:1234:0:0:0:0:0/56")
    end
  end

  describe "mDNS services CSV format" do
    test "builds valid CSV with service data" do
      services = [
        %{
          name: "Test Service",
          type: "_http._tcp",
          port: 8080,
          domain: "local",
          enabled: true,
          source: :api,
          addresses: ["192.168.1.100", "192.168.1.101"],
          txt: %{"version" => "1.0", "path" => "/api"}
        }
      ]

      csv = build_mdns_services_csv(services)

      assert String.contains?(csv, "Service Name,Type,Port,Domain")
      assert String.contains?(csv, "Test Service")
      assert String.contains?(csv, "_http._tcp")
      assert String.contains?(csv, "8080")
      assert String.contains?(csv, "true")
    end

    test "formats multiple IP addresses with semicolons" do
      services = [
        %{
          name: "Multi-IP Service",
          type: "_http._tcp",
          port: 8080,
          domain: "local",
          enabled: true,
          source: :api,
          addresses: ["192.168.1.100", "192.168.1.101", "192.168.1.102"],
          txt: %{}
        }
      ]

      csv = build_mdns_services_csv(services)

      assert String.contains?(csv, "192.168.1.100; 192.168.1.101; 192.168.1.102")
    end

    test "formats TXT records as key=value pairs" do
      services = [
        %{
          name: "Service with TXT",
          type: "_http._tcp",
          port: 8080,
          domain: "local",
          enabled: true,
          source: :file,
          addresses: [],
          txt: %{"version" => "1.0", "path" => "/api", "secure" => "true"}
        }
      ]

      csv = build_mdns_services_csv(services)

      # TXT records should be formatted as key=value pairs
      assert csv =~ ~r/version=1\.0/
      assert csv =~ ~r/path=\/api/
      assert csv =~ ~r/secure=true/
    end
  end

  describe "mDNS discovery CSV format" do
    test "builds valid CSV with discovered services" do
      services = [
        %{
          name: "Discovered Service",
          type: "_http._tcp.local",
          host: "test-host.local",
          port: 8080,
          addresses: ["192.168.1.50"],
          txt: %{"info" => "test"},
          last_seen: 1_735_689_600
        }
      ]

      csv = build_mdns_discovery_csv(services)

      assert String.contains?(csv, "Service Name,Type,Host,Port")
      assert String.contains?(csv, "Discovered Service")
      assert String.contains?(csv, "_http._tcp.local")
      assert String.contains?(csv, "test-host.local")
    end
  end

  describe "DNS ACL CSV format" do
    test "builds valid CSV with ACL rules" do
      acls = [
        %{
          name: "internal-nets",
          description: "Internal network ranges",
          rules: [
            %{action: "allow", network: "192.168.0.0/16"},
            %{action: "allow", network: "10.0.0.0/8"}
          ]
        }
      ]

      csv = build_dns_acl_csv(acls)

      assert String.contains?(csv, "Name,Description,Rules")
      assert String.contains?(csv, "internal-nets")
      assert String.contains?(csv, "Internal network ranges")
    end

    test "formats geo-based ACL rules" do
      acls = [
        %{
          name: "geo-acl",
          description: "Geographic ACL",
          rules: [
            %{action: "allow", geo_countries: ["US", "CA", "GB"]}
          ]
        }
      ]

      csv = build_dns_acl_csv(acls)

      # Geo rules should be formatted with country codes
      assert csv =~ ~r/allow geo/
    end
  end

  describe "DHCPv4 pools filtered_pools/2" do
    alias YellowDog.Console.Dhcpv4Live.PoolsLive

    @pools [
      %{
        name: "office-pool",
        network: "192.168.1.0/24",
        range_start: {192, 168, 1, 100},
        range_end: {192, 168, 1, 200},
        lease_time: 3600
      },
      %{
        name: "guest-wifi",
        network: "10.0.0.0/24",
        range_start: {10, 0, 0, 50},
        range_end: {10, 0, 0, 150},
        lease_time: 1800
      },
      %{
        name: "server-vlan",
        network: "172.16.0.0/16",
        range_start: {172, 16, 0, 10},
        range_end: {172, 16, 0, 50},
        lease_time: 86400
      }
    ]

    test "returns all pools with empty filter" do
      assert PoolsLive.filtered_pools(@pools, "") == @pools
    end

    test "filters by pool name" do
      result = PoolsLive.filtered_pools(@pools, "office")
      assert length(result) == 1
      assert hd(result).name == "office-pool"
    end

    test "filters by network" do
      result = PoolsLive.filtered_pools(@pools, "172.16")
      assert length(result) == 1
      assert hd(result).name == "server-vlan"
    end

    test "filter is case-insensitive" do
      result = PoolsLive.filtered_pools(@pools, "GUEST")
      assert length(result) == 1
      assert hd(result).name == "guest-wifi"
    end

    test "returns empty list when no match" do
      assert PoolsLive.filtered_pools(@pools, "nonexistent") == []
    end
  end

  describe "DHCPv6 pools filtered_pools/2" do
    alias YellowDog.Console.Dhcpv6Live.PoolsLive

    @v6_pools [
      %{
        name: "ipv6-main",
        network: "2001:db8::/32",
        range_start: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
        range_end: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0xFF}
      },
      %{
        name: "ipv6-guest",
        network: "fd00::/64",
        range_start: {0xFD00, 0, 0, 0, 0, 0, 0, 1},
        range_end: {0xFD00, 0, 0, 0, 0, 0, 0, 0xFF}
      }
    ]

    test "returns all pools with empty filter" do
      assert PoolsLive.filtered_pools(@v6_pools, "") == @v6_pools
    end

    test "filters by pool name" do
      result = PoolsLive.filtered_pools(@v6_pools, "guest")
      assert length(result) == 1
      assert hd(result).name == "ipv6-guest"
    end

    test "filters by network prefix" do
      result = PoolsLive.filtered_pools(@v6_pools, "2001")
      assert length(result) == 1
      assert hd(result).name == "ipv6-main"
    end

    test "returns empty list when no match" do
      assert PoolsLive.filtered_pools(@v6_pools, "nonexistent") == []
    end
  end

  describe "Logs filtered_logs/2" do
    alias YellowDog.Console.LogsLive

    @logs [
      %{
        id: 1,
        timestamp: 1_000_000_000,
        level: :info,
        app: :yellow_dog_dns,
        module: nil,
        message: "DNS query received for example.com"
      },
      %{
        id: 2,
        timestamp: 2_000_000_000,
        level: :error,
        app: :yellow_dog_dhcpv4,
        module: nil,
        message: "Pool exhausted: no available addresses"
      },
      %{
        id: 3,
        timestamp: 3_000_000_000,
        level: :warning,
        app: :yellow_dog_mdns,
        module: nil,
        message: "Duplicate service registration attempt"
      },
      %{
        id: 4,
        timestamp: 4_000_000_000,
        level: :debug,
        app: :yellow_dog,
        module: nil,
        message: "Config reload complete"
      }
    ]

    test "returns all logs with empty search" do
      assert LogsLive.filtered_logs(@logs, "") == @logs
    end

    test "filters by message content" do
      result = LogsLive.filtered_logs(@logs, "example.com")
      assert length(result) == 1
      assert hd(result).message =~ "example.com"
    end

    test "search is case-insensitive" do
      result = LogsLive.filtered_logs(@logs, "DNS QUERY")
      assert length(result) == 1
    end

    test "returns empty list when no match" do
      assert LogsLive.filtered_logs(@logs, "nonexistent") == []
    end

    test "matches partial terms" do
      result = LogsLive.filtered_logs(@logs, "pool")
      assert length(result) == 1
      assert hd(result).message =~ "Pool exhausted"
    end
  end

  describe "mDNS monitor filtered_queries/2" do
    alias YellowDog.Console.MdnsLive.MonitorLive

    @queries [
      %{
        name: "_http._tcp.local",
        type: :PTR,
        class: :IN,
        source_ip: {192, 168, 1, 10},
        timestamp: 1_000
      },
      %{
        name: "_ssh._tcp.local",
        type: :PTR,
        class: :IN,
        source_ip: {192, 168, 1, 20},
        timestamp: 2_000
      },
      %{name: "myhost.local", type: :A, class: :IN, source_ip: {10, 0, 0, 5}, timestamp: 3_000}
    ]

    test "returns all queries with empty search" do
      assert MonitorLive.filtered_queries(@queries, "") == @queries
    end

    test "filters by query name" do
      result = MonitorLive.filtered_queries(@queries, "http")
      assert length(result) == 1
      assert hd(result).name == "_http._tcp.local"
    end

    test "filters by source IP" do
      result = MonitorLive.filtered_queries(@queries, "10.0.0")
      assert length(result) == 1
      assert hd(result).name == "myhost.local"
    end

    test "filters by type" do
      result = MonitorLive.filtered_queries(@queries, "ptr")
      assert length(result) == 2
    end

    test "returns empty list when no match" do
      assert MonitorLive.filtered_queries(@queries, "nonexistent") == []
    end
  end

  describe "DNS RR bulk import parse_bulk_preview/2" do
    alias YellowDog.Console.DnsLive.RrLive.Index, as: RrIndex

    test "returns nil for empty text" do
      assert RrIndex.parse_bulk_preview("", "example.com") == nil
    end

    test "returns nil for nil text" do
      assert RrIndex.parse_bulk_preview(nil, "example.com") == nil
    end

    test "parses valid A records" do
      text = "www  3600  IN  A  192.0.2.1\nmail  3600  IN  A  192.0.2.2"
      result = RrIndex.parse_bulk_preview(text, "example.com")

      assert result.status == :ok
      assert result.count == 2
      assert result.types["A"] == 2
    end

    test "parses mixed record types" do
      text = """
      www   3600  IN  A     192.0.2.1
      mail  3600  IN  MX    10 mail.example.com.
      @     3600  IN  TXT   "v=spf1 mx -all"
      """

      result = RrIndex.parse_bulk_preview(text, "example.com")

      assert result.status == :ok
      assert result.count == 3
      assert result.types["A"] == 1
      assert result.types["MX"] == 1
      assert result.types["TXT"] == 1
    end

    test "returns error for invalid zone text" do
      result = RrIndex.parse_bulk_preview("not valid {{{{ bind format @@@@", "example.com")

      # Either returns an error or parses with 0 records
      case result do
        %{status: :error, message: msg} -> assert is_binary(msg)
        %{status: :ok, count: 0} -> :ok
      end
    end

    test "includes record details in preview" do
      text = "www  3600  IN  A  192.0.2.1"
      result = RrIndex.parse_bulk_preview(text, "example.com")

      assert result.status == :ok
      assert length(result.records) == 1
      [record] = result.records
      assert record.type == "A"
    end
  end

  describe "large dataset performance" do
    @tag :performance
    test "handles 10,000 DHCPv4 leases efficiently" do
      leases =
        for i <- 1..10_000 do
          %{
            mac_address: {0x00, 0x11, 0x22, 0x33, div(i, 256), rem(i, 256)},
            ip_address: {192, 168, div(i, 256), rem(i, 256)},
            hostname: "host-#{i}",
            state: :active,
            pool_name: "default",
            allocated_at: 1_735_689_600,
            expires_at: 1_735_776_000
          }
        end

      {time_us, csv} = :timer.tc(fn -> build_dhcpv4_csv(leases) end)

      # Should complete in under 1 second
      assert time_us < 1_000_000
      # CSV should have 10,001 lines (1 header + 10,000 data rows)
      assert length(String.split(csv, "\r\n")) == 10_001
    end
  end

  # Helper functions that mirror the actual implementations

  defp build_dhcpv4_csv(leases) do
    header =
      "MAC Address,IP Address,Hostname,State,Pool,Allocated At,Expires At,Time Remaining\r\n"

    rows =
      Enum.map_join(leases, "\r\n", fn lease ->
        [
          csv_escape(format_mac(lease.mac_address)),
          csv_escape(format_ip(lease.ip_address)),
          csv_escape(lease.hostname || ""),
          csv_escape(to_string(lease.state)),
          csv_escape(lease.pool_name || ""),
          csv_escape(format_timestamp(lease.allocated_at)),
          csv_escape(format_timestamp(lease.expires_at)),
          csv_escape(format_time_remaining(lease.expires_at))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  defp build_dhcpv6_csv(leases) do
    header =
      "DUID,IAID,IA Type,IPv6 Address/Prefix,State,Pool,Preferred Lifetime,Valid Lifetime,Allocated At\r\n"

    rows =
      Enum.map_join(leases, "\r\n", fn lease ->
        [
          csv_escape(format_duid(lease.duid)),
          csv_escape(to_string(lease.iaid)),
          csv_escape(to_string(lease.ia_type)),
          csv_escape(format_ipv6_or_prefix(lease)),
          csv_escape(to_string(lease.state)),
          csv_escape(lease.pool_name || ""),
          csv_escape(format_lifetime(lease.preferred_lifetime)),
          csv_escape(format_lifetime(lease.valid_lifetime)),
          csv_escape(format_timestamp(lease.allocated_at))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  defp build_mdns_services_csv(services) do
    header = "Service Name,Type,Port,Domain,Enabled,Source,IP Addresses,TXT Records\r\n"

    rows =
      Enum.map_join(services, "\r\n", fn service ->
        [
          csv_escape(service.name),
          csv_escape(service.type),
          csv_escape(to_string(service.port)),
          csv_escape(service.domain || "local"),
          csv_escape(to_string(service.enabled)),
          csv_escape(to_string(service.source)),
          csv_escape(format_addresses(service.addresses)),
          csv_escape(format_txt_records(service.txt))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  defp build_mdns_discovery_csv(services) do
    header = "Service Name,Type,Host,Port,IP Addresses,TXT Records,Last Seen\r\n"

    rows =
      Enum.map_join(services, "\r\n", fn service ->
        [
          csv_escape(service.name),
          csv_escape(service.type),
          csv_escape(service.host || ""),
          csv_escape(to_string(service.port || "")),
          csv_escape(format_addresses(service.addresses)),
          csv_escape(format_txt_records(service.txt)),
          csv_escape(format_timestamp(service.last_seen))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  defp build_dns_acl_csv(acls) do
    header = "Name,Description,Rules\r\n"

    rows =
      Enum.map_join(acls, "\r\n", fn acl ->
        [
          csv_escape(acl.name),
          csv_escape(acl.description || ""),
          csv_escape(format_acl_rules(acl.rules))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  # Format helpers

  defp format_mac({a, b, c, d, e, f}) do
    [a, b, c, d, e, f]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_duid(duid) when is_binary(duid) do
    duid
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_ipv6({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.downcase/1)
    |> Enum.join(":")
  end

  defp format_ipv6_or_prefix(%{ia_type: :ia_na, ipv6_address: addr}) when addr != nil do
    format_ipv6(addr)
  end

  defp format_ipv6_or_prefix(%{ia_type: :ia_pd, prefix: prefix, prefix_length: len})
       when prefix != nil and len != nil do
    "#{format_ipv6(prefix)}/#{len}"
  end

  defp format_ipv6_or_prefix(_), do: "N/A"

  defp format_timestamp(timestamp) when is_integer(timestamp) do
    DateTime.from_unix!(timestamp)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  defp format_timestamp(_), do: "N/A"

  defp format_time_remaining(expires_at) when is_integer(expires_at) do
    now = System.system_time(:second)
    remaining = expires_at - now

    cond do
      remaining < 0 -> "Expired"
      remaining < 60 -> "#{remaining}s"
      remaining < 3600 -> "#{div(remaining, 60)}m"
      remaining < 86400 -> "#{div(remaining, 3600)}h"
      true -> "#{div(remaining, 86400)}d"
    end
  end

  defp format_time_remaining(_), do: "N/A"

  defp format_lifetime(lifetime) when is_integer(lifetime) do
    cond do
      lifetime < 60 -> "#{lifetime}s"
      lifetime < 3600 -> "#{div(lifetime, 60)}m"
      lifetime < 86400 -> "#{div(lifetime, 3600)}h"
      true -> "#{div(lifetime, 86400)}d"
    end
  end

  defp format_lifetime(_), do: "N/A"

  defp format_addresses(addresses) when is_list(addresses) do
    Enum.join(addresses, "; ")
  end

  defp format_addresses(_), do: ""

  defp format_txt_records(txt_map) when is_map(txt_map) do
    txt_map
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("; ")
  end

  defp format_txt_records(_), do: ""

  defp format_acl_rules(rules) when is_list(rules) do
    rules
    |> Enum.map(&format_acl_rule/1)
    |> Enum.join("; ")
  end

  defp format_acl_rules(_), do: ""

  defp format_acl_rule(%{action: action, network: network}), do: "#{action} #{network}"

  defp format_acl_rule(%{action: action, geo_countries: countries}) when is_list(countries) do
    "#{action} geo #{Enum.join(countries, ", ")}"
  end

  defp format_acl_rule(%{action: action}), do: "#{action} any"
  defp format_acl_rule(_), do: ""
end
