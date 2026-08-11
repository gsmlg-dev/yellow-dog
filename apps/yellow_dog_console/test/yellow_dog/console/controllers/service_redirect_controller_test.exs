defmodule YellowDog.Console.ServiceRedirectControllerTest do
  use YellowDog.Console.ConnCase, async: true

  @server_legacy_paths [
    "/server/dashboard",
    "/server/dns",
    "/server/dns/zones",
    "/server/dns/zones/new",
    "/server/dns/zones/import",
    "/server/dns/zones/example.org/edit",
    "/server/dns/zones/example.org/records",
    "/server/dns/zones/example.org/records/new",
    "/server/dns/zones/example.org/records/bulk",
    "/server/dns/zones/example.org/records/2/edit",
    "/server/dns/views",
    "/server/dns/views/new",
    "/server/dns/views/default/edit",
    "/server/dns/acl",
    "/server/dns/logs",
    "/server/dns/metrics",
    "/server/dns/providers",
    "/server/dns/providers/new",
    "/server/dns/providers/cloudflare",
    "/server/dns/providers/cloudflare/edit",
    "/server/dns/providers/cloudflare/conflicts",
    "/server/dhcpv4",
    "/server/dhcpv4/leases",
    "/server/dhcpv4/pools",
    "/server/dhcpv4/pools/default",
    "/server/dhcpv4/activity",
    "/server/dhcpv6",
    "/server/dhcpv6/leases",
    "/server/dhcpv6/pools",
    "/server/dhcpv6/pools/default",
    "/server/dhcpv6/activity",
    "/server/mdns",
    "/server/mdns/services",
    "/server/mdns/discovery",
    "/server/mdns/monitor",
    "/server/netboot",
    "/server/netboot/devices",
    "/server/netboot/devices/aa:bb:cc:dd:ee:ff",
    "/server/netboot/profiles",
    "/server/netboot/profiles/new",
    "/server/netboot/profiles/default/edit",
    "/server/netboot/tftp",
    "/server/netboot/log",
    "/server/identity",
    "/server/identity/hosts",
    "/server/identity/hosts/host-01",
    "/server/identity/approvals",
    "/server/identity/tokens",
    "/server/identity/policies",
    "/server/identity/audit",
    "/server/settings",
    "/server/settings/dns",
    "/server/settings/mdns",
    "/server/settings/dhcpv4",
    "/server/settings/dhcpv6",
    "/server/settings/netboot"
  ]

  test "every legacy unscoped Server route redirects only to the Server selector", %{conn: conn} do
    for path <- @server_legacy_paths do
      redirected = conn |> recycle() |> get(path)
      assert redirected.status == 302, "expected #{path} to redirect, got #{redirected.status}"
      assert redirected_to(redirected, 302) == "/server", path
    end
  end

  test "legacy unscoped Netman config always redirects without selecting the reserved ID", %{
    conn: conn
  } do
    redirected = get(conn, "/netman/config")

    assert redirected_to(redirected, 302) == "/netman"
  end

  test "former system service aliases redirect to the matching selector", %{conn: conn} do
    for path <- [
          "/system/logs/dns-query",
          "/system/logs/dhcpv4-activity",
          "/system/logs/dhcpv6-activity",
          "/system/logs/netboot",
          "/system/logs/identity-audit",
          "/system/provider/cloud-dns",
          "/system/fingerprint/devices",
          "/system/fingerprint/devices/aa:bb:cc:dd:ee:ff",
          "/system/fingerprint/fingerprints"
        ] do
      redirected = conn |> recycle() |> get(path)
      assert redirected_to(redirected, 302) == "/server", path
    end
  end

  test "unknown service-shaped paths are not mistaken for legacy routes", %{conn: conn} do
    assert conn |> get("/server/not-a-route") |> response(404) == "Not Found"
    assert conn |> get("/netman/not-a-route/unknown") |> response(404) == "Not Found"
  end

  test "stable service not-found endpoint returns a bounded deterministic body", %{conn: conn} do
    assert conn |> get("/service-not-found/server") |> response(404) == "Server not found"
    assert conn |> get("/service-not-found/netman") |> response(404) == "Netman not found"
    assert conn |> get("/service-not-found/other") |> response(404) == "Service not found"
  end

  test "all operational LiveView routes carry the concrete scope parameter" do
    routes = YellowDog.Console.Router.__routes__()

    server_routes =
      Enum.filter(routes, fn route ->
        String.starts_with?(route.path, "/server/") and
          route.plug not in [
            YellowDog.Console.ServiceRedirectController,
            YellowDog.Console.ServerLive.SelectorLive
          ]
      end)

    netman_routes =
      Enum.filter(routes, fn route ->
        String.starts_with?(route.path, "/netman/") and
          route.plug not in [
            YellowDog.Console.ServiceRedirectController,
            YellowDog.Console.NetmanLive.DashboardLive
          ]
      end)

    assert server_routes != []
    assert netman_routes != []
    assert Enum.all?(server_routes, &String.contains?(&1.path, "/:server_id/"))
    assert Enum.all?(netman_routes, &String.contains?(&1.path, "/:netman_id"))

    assert Enum.any?(routes, &(&1.path == "/server/:server_id/dashboard"))
    assert Enum.any?(routes, &(&1.path == "/netman/:netman_id"))
  end
end
