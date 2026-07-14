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

    assert %NetmanProfile{
             name: :vm,
             features: %{interfaces: true, dhcp_client: false, routes: true, vpn: false},
             apply_mode: :managed
           } = find_profile(ManagementCore.list_netman_profiles(), :vm)

    assert %NetmanProfile{
             name: :observe_only,
             features: %{interfaces: true, link_state: true, routes: false},
             apply_mode: :observe
           } = find_profile(ManagementCore.list_netman_profiles(), :observe_only)
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

  test "caps in-memory events per registry" do
    assert {:ok, %Server{}} =
             ManagementCore.register_server(%{
               id: "srv-capped",
               name: "Server Capped",
               profile: :dns_only
             })

    for index <- 1..505 do
      status_name = "status_#{index}"

      assert {:ok, %Server{status: status}} =
               ManagementCore.update_server_status("srv-capped", status_name)

      assert status == status_name
    end

    events = ManagementCore.list_events()

    assert length(events) == 500
    refute Enum.any?(events, &(&1.type == :server_registered))
    assert hd(events).metadata.status == "status_6"
  end

  test "caps in-memory service registries while allowing replacement" do
    for index <- 1..1_000 do
      id = "srv-#{index}"

      assert {:ok, %Server{id: ^id}} =
               ManagementCore.register_server(%{
                 id: id,
                 name: "Server #{index}",
                 profile: :dns_only
               })
    end

    assert {:error, :registry_full} =
             ManagementCore.register_server(%{
               id: "srv-1001",
               name: "Server 1001",
               profile: :dns_only
             })

    assert {:ok, %Server{id: "srv-1", name: "Server Replacement"}} =
             ManagementCore.register_server(%{
               id: "srv-1",
               name: "Server Replacement",
               profile: :cloud_dns
             })

    for index <- 1..1_000 do
      id = "netman-#{index}"

      assert {:ok, %Netman{id: ^id}} =
               ManagementCore.register_netman(%{
                 id: id,
                 name: "Netman #{index}",
                 profile: :vm
               })
    end

    assert {:error, :registry_full} =
             ManagementCore.register_netman(%{
               id: "netman-1001",
               name: "Netman 1001",
               profile: :vm
             })

    assert {:ok, %Netman{id: "netman-1", name: "Netman Replacement"}} =
             ManagementCore.register_netman(%{
               id: "netman-1",
               name: "Netman Replacement",
               profile: :bare_metal
             })
  end

  test "sanitizes concrete registry payloads before storing them" do
    long_name = String.duplicate("n", 160)
    long_status = String.duplicate("s", 96)
    long_metadata_value = String.duplicate("m", 320)
    metadata = Map.new(1..25, &{"metadata-key-#{&1}", long_metadata_value})

    assert {:ok, %Server{} = server} =
             ManagementCore.register_server(%{
               id: "srv-sanitized",
               name: long_name,
               status: long_status,
               profile: "unknown-server-profile",
               services: %{"dns" => true, "mdns" => "true", "unknown" => true},
               metadata: metadata,
               last_seen_at: long_metadata_value
             })

    assert byte_size(server.name) == 128
    assert byte_size(server.status) == 64
    assert server.profile == :custom
    assert server.services == %{dns: true}
    assert map_size(server.metadata) == 20
    assert server.last_seen_at == nil
    assert Enum.all?(server.metadata, fn {_key, value} -> byte_size(value) == 256 end)

    assert {:ok, %Server{status: status}} =
             ManagementCore.update_server_status("srv-sanitized", long_status)

    assert byte_size(status) == 64

    status_event =
      ManagementCore.list_events()
      |> Enum.find(&(&1.type == :server_status_updated))

    assert byte_size(status_event.metadata.status) == 64

    assert {:error, {:invalid, :id}} =
             ManagementCore.register_server(%{
               id: String.duplicate("s", 129),
               profile: :dns_only
             })

    assert {:ok, %Netman{} = netman} =
             ManagementCore.register_netman(%{
               id: "netman-sanitized",
               name: long_name,
               status: long_status,
               profile: :unknown_netman_profile,
               features: %{"interfaces" => true, "routes" => 1, "unknown" => true},
               metadata: metadata,
               last_seen_at: long_metadata_value
             })

    assert byte_size(netman.name) == 128
    assert byte_size(netman.status) == 64
    assert netman.profile == :custom
    assert netman.features == %{interfaces: true}
    assert map_size(netman.metadata) == 20
    assert netman.last_seen_at == nil

    assert {:error, {:invalid, :id}} =
             ManagementCore.register_netman(%{
               id: String.duplicate("n", 129),
               profile: :vm
             })
  end

  defp find_profile(profiles, name) do
    Enum.find(profiles, &(&1.name == name))
  end
end
