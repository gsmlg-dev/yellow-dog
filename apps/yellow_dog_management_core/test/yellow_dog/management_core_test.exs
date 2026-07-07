defmodule YellowDog.ManagementCoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Event
  alias YellowDog.Management.Netman
  alias YellowDog.Management.NetmanProfile
  alias YellowDog.Management.Server
  alias YellowDog.Management.ServerProfile
  alias YellowDog.ManagementCore

  setup do
    YellowDog.Management.Servers.reset()
    YellowDog.Management.Netmans.reset()

    :ok
  end

  test "registers, lists, fetches, and updates servers in memory" do
    assert [] = ManagementCore.list_servers()

    assert {:ok,
            %Server{
              id: "srv-cloud-1",
              name: "Cloud DNS 1",
              profile: :cloud_dns,
              status: :registered,
              services: %{dns: true}
            }} =
             ManagementCore.register_server(%{
               id: "srv-cloud-1",
               name: "Cloud DNS 1",
               profile: :cloud_dns,
               services: %{dns: true}
             })

    assert [%Server{id: "srv-cloud-1"}] = ManagementCore.list_servers()

    assert {:ok, %Server{id: "srv-cloud-1", status: :registered}} =
             ManagementCore.get_server("srv-cloud-1")

    assert {:ok, %Server{id: "srv-cloud-1", status: :online}} =
             ManagementCore.update_server_status("srv-cloud-1", :online)

    assert {:error, :not_found} = ManagementCore.get_server("missing")
    assert {:error, :not_found} = ManagementCore.update_server_status("missing", :offline)
  end

  test "registers, lists, fetches, and updates Netman instances in memory" do
    assert [] = ManagementCore.list_netmans()

    assert {:ok,
            %Netman{
              id: "netman-cloud-1",
              name: "Cloud Netman 1",
              profile: :cloud_server,
              status: :registered,
              features: %{interfaces: true}
            }} =
             ManagementCore.register_netman(%{
               id: "netman-cloud-1",
               name: "Cloud Netman 1",
               profile: :cloud_server,
               features: %{interfaces: true}
             })

    assert [%Netman{id: "netman-cloud-1"}] = ManagementCore.list_netmans()

    assert {:ok, %Netman{id: "netman-cloud-1", status: :registered}} =
             ManagementCore.get_netman("netman-cloud-1")

    assert {:ok, %Netman{id: "netman-cloud-1", status: :online}} =
             ManagementCore.update_netman_status("netman-cloud-1", :online)

    assert {:error, :not_found} = ManagementCore.get_netman("missing")
    assert {:error, :not_found} = ManagementCore.update_netman_status("missing", :offline)
  end

  test "lists concrete server and Netman profiles" do
    assert %ServerProfile{
             name: :cloud_dns,
             services: %{dns: true, server_agent: true, dhcpv4: false}
           } = find_profile(ManagementCore.list_server_profiles(), :cloud_dns)

    assert %ServerProfile{
             name: :local_network,
             services: %{dns: true, mdns: true, dhcpv4: true, server_agent: true}
           } = find_profile(ManagementCore.list_server_profiles(), :local_network)

    assert %NetmanProfile{
             name: :cloud_server,
             features: %{interfaces: true, dhcp_client: true, routes: true, vpn: false},
             apply_mode: :observe_first
           } = find_profile(ManagementCore.list_netman_profiles(), :cloud_server)

    assert %NetmanProfile{
             name: :vpn_gateway,
             features: %{interfaces: true, routes: true, dns_client: true, vpn: true},
             apply_mode: :managed
           } = find_profile(ManagementCore.list_netman_profiles(), :vpn_gateway)
  end

  test "records concrete management events" do
    assert {:ok, %Server{}} =
             ManagementCore.register_server(%{
               id: "srv-1",
               name: "Server 1",
               profile: :dns_only
             })

    assert {:ok, %Server{}} = ManagementCore.update_server_status("srv-1", :online)

    assert {:ok, %Netman{}} =
             ManagementCore.register_netman(%{
               id: "netman-1",
               name: "Netman 1",
               profile: :vm
             })

    assert [
             %Event{source: :server, source_id: "srv-1", type: :server_registered},
             %Event{source: :server, source_id: "srv-1", type: :server_status_updated},
             %Event{source: :netman, source_id: "netman-1", type: :netman_registered}
           ] = ManagementCore.list_events()
  end

  defp find_profile(profiles, name) do
    Enum.find(profiles, &(&1.name == name))
  end
end
