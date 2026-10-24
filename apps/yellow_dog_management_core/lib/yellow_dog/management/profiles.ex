defmodule YellowDog.Management.Profiles do
  @moduledoc """
  Static concrete profiles for the management foundation.
  """

  alias YellowDog.Management.ServerProfile

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

  @doc "Lists server service keys supported by management core."
  def server_service_keys, do: @server_service_keys

  @doc "Lists server profiles supported by management core."
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
    %ServerProfile{
      name: name,
      description: description,
      services: flags(@server_service_keys, enabled_services)
    }
  end

  defp flags(keys, enabled_keys) do
    enabled = MapSet.new(enabled_keys)

    Map.new(keys, fn key ->
      {key, MapSet.member?(enabled, key)}
    end)
  end
end
