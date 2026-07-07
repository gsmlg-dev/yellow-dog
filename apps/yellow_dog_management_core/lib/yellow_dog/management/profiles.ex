defmodule YellowDog.Management.Profiles do
  @moduledoc """
  Static concrete profiles for the management foundation.
  """

  alias YellowDog.Management.NetmanProfile
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

  @netman_feature_keys [
    :interfaces,
    :dhcp_client,
    :dns_client,
    :routes,
    :link_state,
    :local_status,
    :netman_agent,
    :vpn
  ]

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

  @doc "Lists Netman profiles supported by management core."
  def list_netman_profiles do
    [
      netman_profile(
        :local_server,
        "Local server network manager",
        [
          :interfaces,
          :dhcp_client,
          :dns_client,
          :routes,
          :link_state,
          :local_status,
          :netman_agent
        ],
        :managed
      ),
      netman_profile(
        :cloud_server,
        "Cloud server network manager",
        [
          :interfaces,
          :dhcp_client,
          :dns_client,
          :routes,
          :link_state,
          :local_status,
          :netman_agent
        ],
        :observe_first
      ),
      netman_profile(
        :bare_metal,
        "Bare-metal network manager",
        [
          :interfaces,
          :dhcp_client,
          :dns_client,
          :routes,
          :link_state,
          :local_status,
          :netman_agent
        ],
        :managed
      ),
      netman_profile(
        :vm,
        "Virtual machine network manager",
        [
          :interfaces,
          :dhcp_client,
          :dns_client,
          :routes,
          :link_state,
          :local_status,
          :netman_agent
        ],
        :observe_first
      ),
      netman_profile(
        :vpn_gateway,
        "Future VPN gateway network manager",
        [:interfaces, :routes, :dns_client, :link_state, :local_status, :netman_agent, :vpn],
        :managed
      ),
      netman_profile(
        :observe_only,
        "Observe-only network manager",
        [:interfaces, :routes, :link_state, :local_status, :netman_agent],
        :observe_only
      ),
      netman_profile(:custom, "Custom network manager", [], :custom)
    ]
  end

  defp server_profile(name, description, enabled_services) do
    %ServerProfile{
      name: name,
      description: description,
      services: flags(@server_service_keys, enabled_services)
    }
  end

  defp netman_profile(name, description, enabled_features, apply_mode) do
    %NetmanProfile{
      name: name,
      description: description,
      features: flags(@netman_feature_keys, enabled_features),
      apply_mode: apply_mode
    }
  end

  defp flags(keys, enabled_keys) do
    enabled = MapSet.new(enabled_keys)

    Map.new(keys, fn key ->
      {key, MapSet.member?(enabled, key)}
    end)
  end
end
