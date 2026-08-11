defmodule YellowDog.Console.ServiceRedirectController do
  @moduledoc """
  Redirects legacy unscoped service URLs to an explicit selector.

  Redirects never infer a Server or Netman ID. Unknown paths receive a bounded
  404 response instead of being treated as a legacy service route.
  """

  use YellowDog.Console, :controller

  @server_static_paths MapSet.new([
                         ["dashboard"],
                         ["dns"],
                         ["dns", "zones"],
                         ["dns", "zones", "new"],
                         ["dns", "zones", "import"],
                         ["dns", "views"],
                         ["dns", "views", "new"],
                         ["dns", "acl"],
                         ["dns", "logs"],
                         ["dns", "metrics"],
                         ["dns", "providers"],
                         ["dns", "providers", "new"],
                         ["dhcpv4"],
                         ["dhcpv4", "leases"],
                         ["dhcpv4", "pools"],
                         ["dhcpv4", "activity"],
                         ["dhcpv6"],
                         ["dhcpv6", "leases"],
                         ["dhcpv6", "pools"],
                         ["dhcpv6", "activity"],
                         ["mdns"],
                         ["mdns", "services"],
                         ["mdns", "discovery"],
                         ["mdns", "monitor"],
                         ["netboot"],
                         ["netboot", "devices"],
                         ["netboot", "profiles"],
                         ["netboot", "profiles", "new"],
                         ["netboot", "tftp"],
                         ["netboot", "log"],
                         ["identity"],
                         ["identity", "hosts"],
                         ["identity", "approvals"],
                         ["identity", "tokens"],
                         ["identity", "policies"],
                         ["identity", "audit"],
                         ["settings"],
                         ["settings", "dns"],
                         ["settings", "mdns"],
                         ["settings", "dhcpv4"],
                         ["settings", "dhcpv6"],
                         ["settings", "netboot"]
                       ])

  def server(%{path_params: %{"legacy_path" => path}} = conn, _params) do
    if legacy_server_path?(path), do: redirect(conn, to: "/server"), else: not_found(conn)
  end

  def server(conn, _params), do: redirect(conn, to: "/server")

  def netman(conn, _params), do: redirect(conn, to: "/netman")

  def not_found(%{path_params: %{"service" => "server"}} = conn, _params),
    do: send_resp(conn, 404, "Server not found")

  def not_found(%{path_params: %{"service" => "netman"}} = conn, _params),
    do: send_resp(conn, 404, "Netman not found")

  def not_found(conn, _params), do: send_resp(conn, 404, "Service not found")

  defp legacy_server_path?(path) do
    MapSet.member?(@server_static_paths, path) or legacy_server_resource_path?(path)
  end

  defp legacy_server_resource_path?(["dns", "zones", _zone_id, "edit"]), do: true

  defp legacy_server_resource_path?(["dns", "zones", _zone_id, "records"]), do: true

  defp legacy_server_resource_path?(["dns", "zones", _zone_id, "records", action])
       when action in ["new", "bulk"],
       do: true

  defp legacy_server_resource_path?([
         "dns",
         "zones",
         _zone_id,
         "records",
         _record_index,
         "edit"
       ]),
       do: true

  defp legacy_server_resource_path?(["dns", "views", _view_name, "edit"]), do: true
  defp legacy_server_resource_path?(["dns", "providers", _name]), do: true
  defp legacy_server_resource_path?(["dns", "providers", _name, "edit"]), do: true
  defp legacy_server_resource_path?(["dns", "providers", _name, "conflicts"]), do: true
  defp legacy_server_resource_path?(["dhcpv4", "pools", _pool_name]), do: true
  defp legacy_server_resource_path?(["dhcpv6", "pools", _pool_name]), do: true
  defp legacy_server_resource_path?(["netboot", "devices", _mac]), do: true
  defp legacy_server_resource_path?(["netboot", "profiles", _profile_id, "edit"]), do: true
  defp legacy_server_resource_path?(["identity", "hosts", _host_id]), do: true
  defp legacy_server_resource_path?(_path), do: false

  defp not_found(conn), do: send_resp(conn, 404, "Not Found")
end
