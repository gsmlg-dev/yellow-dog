defmodule YellowDog.Console.ServiceFilterFunctionsTest do
  @moduledoc """
  Unit tests for public filter functions across console LiveViews.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Console.Dhcpv4Live.ActivityLive, as: Dhcpv4Activity
  alias YellowDog.Console.Dhcpv6Live.ActivityLive, as: Dhcpv6Activity
  alias YellowDog.Console.MdnsLive.MonitorLive
  alias YellowDog.Console.FormatHelper
  alias YellowDog.Console.NetbootLive.DevicesLive, as: NetbootDevices
  alias YellowDog.Console.NetbootLive.ProfilesLive, as: NetbootProfiles
  alias YellowDog.Console.NetbootLive.TftpLive, as: NetbootTftp
  alias YellowDog.Console.NetbootLive.LogLive, as: NetbootLog
  alias YellowDog.Console.FingerprintLive.FingerprintsLive
  alias YellowDog.Console.FingerprintLive.DevicesLive, as: FingerprintDevices

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
      %{
        type: :discover,
        client_mac: "AA:BB:CC:DD:EE:01",
        client_ip: "192.168.1.10",
        details: "DISCOVER from office"
      },
      %{
        type: :ack,
        client_mac: "AA:BB:CC:DD:EE:02",
        client_ip: "10.0.0.5",
        details: "ACK for guest"
      },
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
      %{
        type: :solicit,
        client_duid: "00:01:00:01:AA:BB",
        client_ip: "2001:db8::1",
        details: "SOLICIT"
      },
      %{
        type: :reply,
        client_duid: "00:01:00:01:CC:DD",
        client_ip: "fd00::5",
        details: "REPLY granted"
      },
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

  # ============================================================================
  # FormatHelper.filtered_countries/2
  # ============================================================================

  describe "FormatHelper.filtered_countries/2" do
    @countries [
      %{code: "US", name: "United States"},
      %{code: "GB", name: "United Kingdom"},
      %{code: "DE", name: "Germany"}
    ]

    test "returns all with empty search" do
      assert length(FormatHelper.filtered_countries(@countries, "")) == 3
    end

    test "filters by country code" do
      result = FormatHelper.filtered_countries(@countries, "US")
      assert length(result) == 1
      assert hd(result).code == "US"
    end

    test "filters by country name" do
      result = FormatHelper.filtered_countries(@countries, "kingdom")
      assert length(result) == 1
      assert hd(result).code == "GB"
    end

    test "case-insensitive search" do
      assert length(FormatHelper.filtered_countries(@countries, "united")) == 2
    end

    test "returns empty for non-matching search" do
      assert FormatHelper.filtered_countries(@countries, "zzz") == []
    end
  end

  # ============================================================================
  # FormatHelper.filter_by_state/2
  # ============================================================================

  describe "FormatHelper.filter_by_state/2" do
    @stateful_items [
      %{name: "a", state: :active},
      %{name: "b", state: :expired},
      %{name: "c", state: :active}
    ]

    test "returns all with 'all' filter" do
      assert length(FormatHelper.filter_by_state(@stateful_items, "all")) == 3
    end

    test "filters by state string" do
      result = FormatHelper.filter_by_state(@stateful_items, "active")
      assert length(result) == 2
    end

    test "returns empty for non-matching state" do
      assert FormatHelper.filter_by_state(@stateful_items, "pending") == []
    end
  end

  # ============================================================================
  # FormatHelper.filter_by_pool/2
  # ============================================================================

  describe "FormatHelper.filter_by_pool/2" do
    @pooled_items [
      %{name: "x", pool_name: "office"},
      %{name: "y", pool_name: "guest"},
      %{name: "z", pool_name: "office"}
    ]

    test "returns all with 'all' filter" do
      assert length(FormatHelper.filter_by_pool(@pooled_items, "all")) == 3
    end

    test "filters by pool name" do
      result = FormatHelper.filter_by_pool(@pooled_items, "office")
      assert length(result) == 2
    end

    test "returns empty for non-matching pool" do
      assert FormatHelper.filter_by_pool(@pooled_items, "dmz") == []
    end
  end

  # ============================================================================
  # NetbootDevices filter functions
  # ============================================================================

  describe "NetbootDevices.filter_by_search/2" do
    @nb_devices [
      %{mac: "AA:BB:CC:DD:EE:01", hostname: "server-1", profile_id: "ubuntu-22", tags: ["prod"]},
      %{mac: "AA:BB:CC:DD:EE:02", hostname: "desktop-2", profile_id: "centos-9", tags: ["dev"]},
      %{mac: "AA:BB:CC:DD:EE:03", hostname: nil, profile_id: nil, tags: []}
    ]

    test "returns all with empty search" do
      assert length(NetbootDevices.filter_by_search(@nb_devices, "")) == 3
    end

    test "filters by MAC" do
      result = NetbootDevices.filter_by_search(@nb_devices, "EE:01")
      assert length(result) == 1
    end

    test "filters by hostname" do
      result = NetbootDevices.filter_by_search(@nb_devices, "server")
      assert length(result) == 1
    end

    test "filters by profile_id" do
      result = NetbootDevices.filter_by_search(@nb_devices, "ubuntu")
      assert length(result) == 1
    end

    test "filters by tag" do
      result = NetbootDevices.filter_by_search(@nb_devices, "prod")
      assert length(result) == 1
    end

    test "case-insensitive search" do
      result = NetbootDevices.filter_by_search(@nb_devices, "SERVER")
      assert length(result) == 1
    end

    test "handles nil hostname and profile_id" do
      result = NetbootDevices.filter_by_search(@nb_devices, "nonexistent")
      assert result == []
    end
  end

  describe "NetbootDevices.filter_by_state/2" do
    @nb_state_devices [
      %{mac: "a", state: :new},
      %{mac: "b", state: :provisioned},
      %{mac: "c", state: :new}
    ]

    test "returns all with 'all'" do
      assert length(NetbootDevices.filter_by_state(@nb_state_devices, "all")) == 3
    end

    test "filters by state" do
      result = NetbootDevices.filter_by_state(@nb_state_devices, "new")
      assert length(result) == 2
    end
  end

  describe "NetbootDevices.filter_by_profile/2" do
    @nb_profile_devices [
      %{mac: "a", profile_id: "ubuntu-22"},
      %{mac: "b", profile_id: "centos-9"},
      %{mac: "c", profile_id: nil}
    ]

    test "returns all with 'all'" do
      assert length(NetbootDevices.filter_by_profile(@nb_profile_devices, "all")) == 3
    end

    test "filters unassigned" do
      result = NetbootDevices.filter_by_profile(@nb_profile_devices, "unassigned")
      assert length(result) == 1
      assert hd(result).profile_id == nil
    end

    test "filters by specific profile" do
      result = NetbootDevices.filter_by_profile(@nb_profile_devices, "ubuntu-22")
      assert length(result) == 1
    end
  end

  describe "NetbootDevices.sort_devices/3" do
    @sortable_devices [
      %{mac: "CC:CC", hostname: "bravo", state: :new, profile_id: nil, install_attempts: 3, last_seen: ~U[2025-01-02 00:00:00Z], arch: :x86_64, tags: []},
      %{mac: "AA:AA", hostname: "alpha", state: :provisioned, profile_id: "ubuntu", install_attempts: 1, last_seen: ~U[2025-01-03 00:00:00Z], arch: :aarch64, tags: []},
      %{mac: "BB:BB", hostname: nil, state: :new, profile_id: nil, install_attempts: 0, last_seen: nil, arch: nil, tags: []}
    ]

    test "sorts by mac ascending" do
      result = NetbootDevices.sort_devices(@sortable_devices, "mac", "asc")
      assert Enum.map(result, & &1.mac) == ["AA:AA", "BB:BB", "CC:CC"]
    end

    test "sorts by mac descending" do
      result = NetbootDevices.sort_devices(@sortable_devices, "mac", "desc")
      assert Enum.map(result, & &1.mac) == ["CC:CC", "BB:BB", "AA:AA"]
    end

    test "sorts by hostname with nil handling" do
      result = NetbootDevices.sort_devices(@sortable_devices, "hostname", "asc")
      assert hd(result).hostname == nil || hd(result).hostname == ""
    end

    test "sorts by install_attempts" do
      result = NetbootDevices.sort_devices(@sortable_devices, "install_attempts", "asc")
      assert Enum.map(result, & &1.install_attempts) == [0, 1, 3]
    end

    test "sorts by unknown field falls back to mac" do
      result = NetbootDevices.sort_devices(@sortable_devices, "unknown_field", "asc")
      assert Enum.map(result, & &1.mac) == ["AA:AA", "BB:BB", "CC:CC"]
    end
  end

  # ============================================================================
  # NetbootProfiles.filter_by_search/2
  # ============================================================================

  describe "NetbootProfiles.filter_by_search/2" do
    @nb_profiles [
      %{id: "ubuntu-22", description: "Ubuntu 22.04 LTS", kernel: "vmlinuz", initrd: "initrd.gz"},
      %{id: "centos-9", description: "CentOS Stream 9", kernel: "vmlinuz-centos", initrd: nil}
    ]

    test "returns all with empty search" do
      assert length(NetbootProfiles.filter_by_search(@nb_profiles, "")) == 2
    end

    test "filters by id" do
      result = NetbootProfiles.filter_by_search(@nb_profiles, "ubuntu")
      assert length(result) == 1
    end

    test "filters by description" do
      result = NetbootProfiles.filter_by_search(@nb_profiles, "Stream")
      assert length(result) == 1
    end

    test "filters by kernel" do
      result = NetbootProfiles.filter_by_search(@nb_profiles, "centos")
      assert length(result) == 1
    end

    test "case-insensitive search" do
      result = NetbootProfiles.filter_by_search(@nb_profiles, "UBUNTU")
      assert length(result) == 1
    end
  end

  # ============================================================================
  # NetbootTftp.filtered_history/2
  # ============================================================================

  describe "NetbootTftp.filtered_history/2" do
    @tftp_history [
      %{file_path: "/boot/vmlinuz", client_addr: {192, 168, 1, 10}},
      %{file_path: "/boot/initrd.gz", client_addr: {10, 0, 0, 5}}
    ]

    test "returns all with empty search" do
      assert length(NetbootTftp.filtered_history(@tftp_history, "")) == 2
    end

    test "filters by file path" do
      result = NetbootTftp.filtered_history(@tftp_history, "vmlinuz")
      assert length(result) == 1
    end

    test "filters by client address" do
      result = NetbootTftp.filtered_history(@tftp_history, "192.168")
      assert length(result) == 1
    end

    test "returns empty for non-matching search" do
      assert NetbootTftp.filtered_history(@tftp_history, "zzz") == []
    end
  end

  describe "NetbootTftp.sort_history/3" do
    @sortable_history [
      %{file_path: "/boot/a.img", bytes: 100, status: :ok, completed_at: ~U[2025-01-02 00:00:00Z]},
      %{file_path: "/boot/c.img", bytes: 300, status: :error, completed_at: ~U[2025-01-01 00:00:00Z]},
      %{file_path: "/boot/b.img", bytes: 200, status: :ok, completed_at: ~U[2025-01-03 00:00:00Z]}
    ]

    test "sorts by file ascending" do
      result = NetbootTftp.sort_history(@sortable_history, "file", "asc")
      assert Enum.map(result, & &1.file_path) == ["/boot/a.img", "/boot/b.img", "/boot/c.img"]
    end

    test "sorts by file descending" do
      result = NetbootTftp.sort_history(@sortable_history, "file", "desc")
      assert Enum.map(result, & &1.file_path) == ["/boot/c.img", "/boot/b.img", "/boot/a.img"]
    end

    test "sorts by size ascending" do
      result = NetbootTftp.sort_history(@sortable_history, "size", "asc")
      assert Enum.map(result, & &1.bytes) == [100, 200, 300]
    end

    test "sorts by time ascending" do
      result = NetbootTftp.sort_history(@sortable_history, "time", "asc")
      assert hd(result).completed_at == ~U[2025-01-01 00:00:00Z]
    end
  end

  describe "NetbootTftp.flatten_tree/1" do
    test "flattens empty list" do
      assert NetbootTftp.flatten_tree([]) == []
    end

    test "flattens flat file list" do
      files = [
        %{type: :file, path: "a.txt", size: 10},
        %{type: :file, path: "b.txt", size: 20}
      ]

      assert length(NetbootTftp.flatten_tree(files)) == 2
    end

    test "flattens nested directories" do
      tree = [
        %{type: :directory, path: "boot", children: [
          %{type: :file, path: "boot/vmlinuz", size: 1000},
          %{type: :file, path: "boot/initrd", size: 2000}
        ]},
        %{type: :file, path: "readme.txt", size: 50}
      ]

      result = NetbootTftp.flatten_tree(tree)
      assert length(result) == 3
      assert Enum.all?(result, &(&1.type == :file))
    end

    test "flattens deeply nested directories" do
      tree = [
        %{type: :directory, path: "a", children: [
          %{type: :directory, path: "a/b", children: [
            %{type: :file, path: "a/b/deep.txt", size: 5}
          ]}
        ]}
      ]

      result = NetbootTftp.flatten_tree(tree)
      assert length(result) == 1
      assert hd(result).path == "a/b/deep.txt"
    end
  end

  # ============================================================================
  # NetbootLog filter functions
  # ============================================================================

  describe "NetbootLog.filtered_entries/4" do
    @log_entries [
      %{type: "device", level: "info", message: "Device registered AA:BB"},
      %{type: "tftp", level: "error", message: "Transfer failed for /boot/vmlinuz"},
      %{type: "device", level: "warning", message: "Device timeout"},
      %{type: "tftp", level: "info", message: "Transfer complete"}
    ]

    test "returns all with no filters" do
      assert length(NetbootLog.filtered_entries(@log_entries, "", "all", "all")) == 4
    end

    test "filters by type" do
      result = NetbootLog.filtered_entries(@log_entries, "", "device", "all")
      assert length(result) == 2
    end

    test "filters by error level" do
      result = NetbootLog.filtered_entries(@log_entries, "", "all", "error")
      assert length(result) == 1
      assert hd(result).level == "error"
    end

    test "warning level includes errors" do
      result = NetbootLog.filtered_entries(@log_entries, "", "all", "warning")
      assert length(result) == 2
      assert Enum.all?(result, &(&1.level in ["warning", "error"]))
    end

    test "filters by search text" do
      result = NetbootLog.filtered_entries(@log_entries, "vmlinuz", "all", "all")
      assert length(result) == 1
    end

    test "combines type and search" do
      result = NetbootLog.filtered_entries(@log_entries, "Transfer", "tftp", "all")
      assert length(result) == 2
    end

    test "handles empty entries" do
      assert NetbootLog.filtered_entries([], "test", "all", "all") == []
    end
  end

  # ============================================================================
  # FingerprintsLive.filter_by_search/2
  # ============================================================================

  describe "FingerprintsLive.filter_by_search/2" do
    @fingerprints [
      %{vendor_class: "MSFT 5.0", profile_id: "windows", parameter_list: [1, 3, 6]},
      %{vendor_class: "dhcpcd-9.4.1", profile_id: "linux", parameter_list: [1, 28, 121]},
      %{vendor_class: nil, profile_id: nil, parameter_list: nil}
    ]

    test "returns all with empty search" do
      assert length(FingerprintsLive.filter_by_search(@fingerprints, "")) == 3
    end

    test "filters by vendor_class" do
      result = FingerprintsLive.filter_by_search(@fingerprints, "MSFT")
      assert length(result) == 1
    end

    test "filters by profile_id" do
      result = FingerprintsLive.filter_by_search(@fingerprints, "linux")
      assert length(result) == 1
    end

    test "filters by parameter_list" do
      result = FingerprintsLive.filter_by_search(@fingerprints, "121")
      assert length(result) == 1
    end

    test "handles nil fields" do
      result = FingerprintsLive.filter_by_search(@fingerprints, "nonexistent")
      assert result == []
    end
  end

  # ============================================================================
  # FingerprintDevices.filter_by_search/2 and filter_by_type/2
  # ============================================================================

  describe "FingerprintDevices.filter_by_search/2" do
    @fp_devices [
      %{
        mac: "AA:BB:CC:DD:EE:01",
        hostname: "office-pc",
        oui_vendor: "Dell",
        ipv4_addresses: ["192.168.1.10"],
        ipv6_addresses: []
      },
      %{
        mac: "AA:BB:CC:DD:EE:02",
        hostname: nil,
        oui_vendor: nil,
        ipv4_addresses: [],
        ipv6_addresses: ["2001:db8::1"]
      }
    ]

    test "returns all with empty search" do
      assert length(FingerprintDevices.filter_by_search(@fp_devices, "")) == 2
    end

    test "filters by MAC" do
      result = FingerprintDevices.filter_by_search(@fp_devices, "EE:01")
      assert length(result) == 1
    end

    test "filters by hostname" do
      result = FingerprintDevices.filter_by_search(@fp_devices, "office")
      assert length(result) == 1
    end

    test "filters by vendor" do
      result = FingerprintDevices.filter_by_search(@fp_devices, "Dell")
      assert length(result) == 1
    end

    test "filters by IPv4 address" do
      result = FingerprintDevices.filter_by_search(@fp_devices, "192.168")
      assert length(result) == 1
    end

    test "filters by IPv6 address" do
      result = FingerprintDevices.filter_by_search(@fp_devices, "2001:db8")
      assert length(result) == 1
    end
  end

  describe "FingerprintDevices.filter_by_type/2" do
    @typed_devices [
      %{mac: "a", profile_id: "windows"},
      %{mac: "b", profile_id: "linux"},
      %{mac: "c", profile_id: "windows"}
    ]

    test "returns all with 'all'" do
      assert length(FingerprintDevices.filter_by_type(@typed_devices, "all")) == 3
    end

    test "filters by profile type" do
      result = FingerprintDevices.filter_by_type(@typed_devices, "windows")
      assert length(result) == 2
    end

    test "returns empty for non-matching type" do
      assert FingerprintDevices.filter_by_type(@typed_devices, "macos") == []
    end
  end
end
