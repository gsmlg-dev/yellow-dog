defmodule YellowDog.Console.ServicePaths do
  @moduledoc """
  Builds service paths from an explicit Server or Netman selection.

  Every dynamic value is encoded as one complete path segment. This module
  deliberately exposes named destinations instead of rewriting an existing
  path, so nested resource identifiers cannot replace the selected runtime.
  """

  @max_id_bytes 128
  @reserved_server_ids ["settings"]
  @reserved_netman_ids ["config"]

  @server_paths %{
    dashboard: "/dashboard",
    dns: "/dns",
    dns_zones: "/dns/zones",
    dns_zone_new: "/dns/zones/new",
    dns_zone_import: "/dns/zones/import",
    dns_views: "/dns/views",
    dns_view_new: "/dns/views/new",
    dns_acl: "/dns/acl",
    dns_logs: "/dns/logs",
    dns_metrics: "/dns/metrics",
    dns_providers: "/dns/providers",
    dns_provider_new: "/dns/providers/new",
    dns_cloud_provider: "/dns/cloud-provider",
    dhcpv4: "/dhcpv4",
    dhcpv4_leases: "/dhcpv4/leases",
    dhcpv4_pools: "/dhcpv4/pools",
    dhcpv4_activity: "/dhcpv4/activity",
    dhcpv6: "/dhcpv6",
    dhcpv6_leases: "/dhcpv6/leases",
    dhcpv6_pools: "/dhcpv6/pools",
    dhcpv6_activity: "/dhcpv6/activity",
    mdns: "/mdns",
    mdns_services: "/mdns/services",
    mdns_discovery: "/mdns/discovery",
    mdns_monitor: "/mdns/monitor",
    netboot: "/netboot",
    netboot_devices: "/netboot/devices",
    netboot_profiles: "/netboot/profiles",
    netboot_profile_new: "/netboot/profiles/new",
    netboot_tftp: "/netboot/tftp",
    netboot_log: "/netboot/log",
    identity: "/identity",
    identity_hosts: "/identity/hosts",
    identity_approvals: "/identity/approvals",
    identity_tokens: "/identity/tokens",
    identity_policies: "/identity/policies",
    identity_audit: "/identity/audit",
    fingerprint_devices: "/fingerprint/devices",
    fingerprint_fingerprints: "/fingerprint/fingerprints",
    settings: "/settings",
    settings_dns: "/settings/dns",
    settings_mdns: "/settings/mdns",
    settings_dhcpv4: "/settings/dhcpv4",
    settings_dhcpv6: "/settings/dhcpv6",
    settings_netboot: "/settings/netboot"
  }

  @netman_paths %{
    overview: "",
    dashboard: "",
    config: "/config",
    interfaces: "/interfaces",
    resolved: "/resolved",
    dhcp_client: "/dhcp-client"
  }

  @spec server_path(String.t(), atom() | tuple()) :: String.t()
  def server_path(server_id, destination) do
    "/server/#{selected_segment!(server_id, :server)}#{server_suffix!(destination)}"
  end

  @spec netman_path(String.t(), atom()) :: String.t()
  def netman_path(netman_id, destination) do
    "/netman/#{selected_segment!(netman_id, :netman)}#{netman_suffix!(destination)}"
  end

  @spec valid_server_id?(term()) :: boolean()
  def valid_server_id?(server_id),
    do: valid_id?(server_id) and server_id not in @reserved_server_ids

  @spec valid_netman_id?(term()) :: boolean()
  def valid_netman_id?(netman_id),
    do: valid_id?(netman_id) and netman_id not in @reserved_netman_ids

  defp server_suffix!(destination) when is_atom(destination) do
    case Map.fetch(@server_paths, destination) do
      {:ok, suffix} -> suffix
      :error -> raise ArgumentError, "unknown Server destination: #{inspect(destination)}"
    end
  end

  defp server_suffix!({:dns_zone_edit, zone_id}),
    do: "/dns/zones/#{resource_segment!(zone_id)}/edit"

  defp server_suffix!({:dns_zone_records, zone_id}),
    do: "/dns/zones/#{resource_segment!(zone_id)}/records"

  defp server_suffix!({:dns_zone_record_new, zone_id}),
    do: "/dns/zones/#{resource_segment!(zone_id)}/records/new"

  defp server_suffix!({:dns_zone_records_bulk, zone_id}),
    do: "/dns/zones/#{resource_segment!(zone_id)}/records/bulk"

  defp server_suffix!({:dns_zone_record_edit, zone_id, record_index}),
    do: "/dns/zones/#{resource_segment!(zone_id)}/records/#{resource_segment!(record_index)}/edit"

  defp server_suffix!({:dns_view_edit, view_name}),
    do: "/dns/views/#{resource_segment!(view_name)}/edit"

  defp server_suffix!({:dns_provider, name}),
    do: "/dns/providers/#{resource_segment!(name)}"

  defp server_suffix!({:dns_provider_edit, name}),
    do: "/dns/providers/#{resource_segment!(name)}/edit"

  defp server_suffix!({:dns_provider_conflicts, name}),
    do: "/dns/providers/#{resource_segment!(name)}/conflicts"

  defp server_suffix!({:dhcpv4_pool, pool_name}),
    do: "/dhcpv4/pools/#{resource_segment!(pool_name)}"

  defp server_suffix!({:dhcpv6_pool, pool_name}),
    do: "/dhcpv6/pools/#{resource_segment!(pool_name)}"

  defp server_suffix!({:netboot_device, mac}),
    do: "/netboot/devices/#{resource_segment!(mac)}"

  defp server_suffix!({:netboot_profile_edit, profile_id}),
    do: "/netboot/profiles/#{resource_segment!(profile_id)}/edit"

  defp server_suffix!({:identity_host, host_id}),
    do: "/identity/hosts/#{resource_segment!(host_id)}"

  defp server_suffix!({:fingerprint_device, mac}),
    do: "/fingerprint/devices/#{resource_segment!(mac)}"

  defp server_suffix!(destination) do
    raise ArgumentError, "unknown Server destination: #{inspect(destination)}"
  end

  defp netman_suffix!(destination) do
    case Map.fetch(@netman_paths, destination) do
      {:ok, suffix} -> suffix
      :error -> raise ArgumentError, "unknown Netman destination: #{inspect(destination)}"
    end
  end

  defp selected_segment!(value, :server) do
    if valid_server_id?(value), do: encode_segment(value), else: invalid_id!(:server, value)
  end

  defp selected_segment!(value, :netman) do
    if valid_netman_id?(value), do: encode_segment(value), else: invalid_id!(:netman, value)
  end

  defp resource_segment!(value) when is_integer(value) and value >= 0,
    do: Integer.to_string(value)

  defp resource_segment!(value) do
    if valid_id?(value), do: encode_segment(value), else: invalid_id!(:resource, value)
  end

  defp valid_id?(value) do
    is_binary(value) and value != "" and byte_size(value) <= @max_id_bytes and
      String.valid?(value) and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"])
  end

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp invalid_id!(type, value) do
    raise ArgumentError, "invalid #{type} identifier: #{inspect(value)}"
  end
end
