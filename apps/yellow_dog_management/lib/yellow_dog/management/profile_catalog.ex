defmodule YellowDog.Management.ProfileCatalog do
  @moduledoc """
  Pure catalog metadata copied from the original Management Profiles catalog.

  Presets describe historical defaults, not actual Worker runtime support.
  Reading this catalog does not start agents or enable services.
  """

  @server_service_keys [
    :dns,
    :mdns,
    :dhcpv4,
    :dhcpv6,
    :netboot,
    :identity,
    :fingerprint,
    :server_agent
  ]

  def server_service_keys, do: @server_service_keys

  def list_server_profiles do
    [
      server_profile(:cloud_dns, "Cloud DNS server", [:dns, :server_agent]),
      server_profile(:local_network, "Local network server", @server_service_keys),
      server_profile(:dns_only, "DNS-only server", [:dns, :server_agent]),
      server_profile(:dhcp_only, "DHCP-only server", [:dhcpv4, :dhcpv6, :server_agent]),
      server_profile(:netboot_only, "Netboot-only server", [:netboot, :server_agent]),
      server_profile(:custom, "Custom server", [])
    ]
  end

  defp server_profile(name, description, enabled_services) do
    %{
      name: name,
      description: description,
      services: flags(@server_service_keys, enabled_services)
    }
  end

  defp flags(keys, enabled_keys) do
    enabled = MapSet.new(enabled_keys)
    Map.new(keys, fn key -> {key, MapSet.member?(enabled, key)} end)
  end
end
