defmodule YellowDog.Console.ServicePathsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.ServicePaths

  test "builds explicit Server paths without losing nested resource identifiers" do
    assert ServicePaths.server_path("server-01", :dashboard) == "/server/server-01/dashboard"

    assert ServicePaths.server_path("server-01", {:dns_zone_records, "example.org"}) ==
             "/server/server-01/dns/zones/example.org/records"

    assert ServicePaths.server_path(
             "server-01",
             {:dns_zone_record_edit, "example.org", 7}
           ) == "/server/server-01/dns/zones/example.org/records/7/edit"

    assert ServicePaths.server_path("server-01", {:netboot_device, "aa:bb:cc:dd:ee:ff"}) ==
             "/server/server-01/netboot/devices/aa%3Abb%3Acc%3Add%3Aee%3Aff"
  end

  test "builds every top-level Server service destination with the selected ID" do
    assert ServicePaths.server_path("server-01", :dns) == "/server/server-01/dns"
    assert ServicePaths.server_path("server-01", :dhcpv4) == "/server/server-01/dhcpv4"
    assert ServicePaths.server_path("server-01", :dhcpv6) == "/server/server-01/dhcpv6"
    assert ServicePaths.server_path("server-01", :mdns) == "/server/server-01/mdns"
    assert ServicePaths.server_path("server-01", :netboot) == "/server/server-01/netboot"
    assert ServicePaths.server_path("server-01", :identity) == "/server/server-01/identity"
    assert ServicePaths.server_path("server-01", :settings) == "/server/server-01/settings"

    assert ServicePaths.server_path("server-01", :fingerprint_devices) ==
             "/server/server-01/fingerprint/devices"
  end

  test "builds explicit Netman paths" do
    assert ServicePaths.netman_path("netman-01", :overview) == "/netman/netman-01"
    assert ServicePaths.netman_path("netman-01", :config) == "/netman/netman-01/config"

    assert ServicePaths.netman_path("netman-01", :interfaces) ==
             "/netman/netman-01/interfaces"

    assert ServicePaths.netman_path("netman-01", :resolved) ==
             "/netman/netman-01/resolved"

    assert ServicePaths.netman_path("netman-01", :dhcp_client) ==
             "/netman/netman-01/dhcp-client"
  end

  test "percent-encodes identifiers as complete path segments" do
    assert ServicePaths.server_path("server one@北京", :dashboard) ==
             "/server/server%20one%40%E5%8C%97%E4%BA%AC/dashboard"

    assert ServicePaths.netman_path("netman one@北京", :overview) ==
             "/netman/netman%20one%40%E5%8C%97%E4%BA%AC"

    assert ServicePaths.server_path("server-01", {:dns_zone_records, "a b.example"}) ==
             "/server/server-01/dns/zones/a%20b.example/records"
  end

  test "rejects malformed, overlong, traversal, and reserved identifiers" do
    for invalid <- ["", String.duplicate("a", 129), ".", "..", "a/b", "a\\b"] do
      assert_raise ArgumentError, fn -> ServicePaths.server_path(invalid, :dashboard) end
      assert_raise ArgumentError, fn -> ServicePaths.netman_path(invalid, :overview) end
    end

    assert_raise ArgumentError, fn -> ServicePaths.netman_path("config", :overview) end
    assert_raise ArgumentError, fn -> ServicePaths.server_path("settings", :dashboard) end
  end
end
