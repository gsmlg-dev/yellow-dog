defmodule YellowDog.Netman.Control.NetworkTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Control
  alias YellowDog.Netman.Control.Network
  alias YellowDog.Netman.Kernel.LinkMonitor
  alias YellowDog.Netman.RuntimeState
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.Operation

  @sent_at ~U[2026-07-18 00:00:00Z]

  setup do
    LinkMonitor.list_links()
    |> Enum.each(&MockNetlink.link_removed(&1.interface))

    assert LinkMonitor.list_links() == []

    runtime_state = :sys.get_state(RuntimeState)

    :sys.replace_state(RuntimeState, fn state ->
      %{state | apply_mode: :managed, features: all_features()}
    end)

    on_exit(fn ->
      :sys.replace_state(RuntimeState, fn _state -> runtime_state end)
    end)
  end

  test "lists every observed link, address, and routed gateway as an explicit item" do
    suffix = System.unique_integer([:positive])
    interfaces = [interface("nwa", suffix), interface("nwb", suffix)]
    [first, second] = interfaces

    MockNetlink.link_up(first, index: 101)
    MockNetlink.link_down(second, index: 102)
    MockNetlink.address_added(first, "192.0.2.10/24")
    MockNetlink.address_added(second, "198.51.100.20/24", scope: "link")
    MockNetlink.route_added(interface: first, gateway: "192.0.2.1")

    MockNetlink.route_added(
      interface: second,
      destination: "198.51.100.0/24",
      gateway: "198.51.100.1"
    )

    on_exit(fn ->
      MockNetlink.route_removed(interface: first, gateway: "192.0.2.1")

      MockNetlink.route_removed(
        interface: second,
        destination: "198.51.100.0/24",
        gateway: "198.51.100.1"
      )

      MockNetlink.address_removed(first, "192.0.2.10/24")
      MockNetlink.address_removed(second, "198.51.100.20/24", scope: "link")
      Enum.each(interfaces, &MockNetlink.link_removed/1)
    end)

    assert {:ok, links} = Network.dispatch("netman.network.links.list", %{})

    assert Enum.filter(links["items"], &(&1["link_id"] in interfaces)) == [
             %{"link_id" => first, "name" => first, "state" => "up"},
             %{"link_id" => second, "name" => second, "state" => "down"}
           ]

    assert {:ok, addresses} = Network.dispatch("netman.network.addresses.list", %{})

    assert Enum.filter(addresses["items"], &(&1["link_id"] in interfaces)) == [
             %{"link_id" => first, "address" => "192.0.2.10/24", "scope" => "global"},
             %{"link_id" => second, "address" => "198.51.100.20/24", "scope" => "link"}
           ]

    assert {:ok, routes} = Network.dispatch("netman.network.routes.list", %{})

    assert Enum.filter(routes["items"], &(&1["link_id"] in interfaces)) == [
             %{
               "destination" => "0.0.0.0/0",
               "gateway" => "192.0.2.1",
               "link_id" => first
             },
             %{
               "destination" => "198.51.100.0/24",
               "gateway" => "198.51.100.1",
               "link_id" => second
             }
           ]

    for {operation, result} <- [
          {"netman.network.links.list", links},
          {"netman.network.addresses.list", addresses},
          {"netman.network.routes.list", routes}
        ] do
      assert_valid_result(operation, result)
      assert is_binary(result["revision"])
      assert is_binary(result["observed_at"])
    end

    assert {:ok, %{"items" => [%{"link_id" => ^second}]}} =
             Network.dispatch("netman.network.links.list", %{
               "cursor" => first,
               "limit" => 1
             })
  end

  test "preserves an on-link route with an explicit null gateway" do
    suffix = System.unique_integer([:positive])
    interface = interface("nwo", suffix)

    MockNetlink.link_up(interface, index: 103)

    MockNetlink.route_added(
      interface: interface,
      destination: "192.0.2.0/24",
      gateway: nil,
      scope: "link"
    )

    on_exit(fn ->
      MockNetlink.route_removed(
        interface: interface,
        destination: "192.0.2.0/24",
        gateway: nil,
        scope: "link"
      )

      MockNetlink.link_removed(interface)
    end)

    assert {:ok, routes} = Network.dispatch("netman.network.routes.list", %{})

    assert %{
             "destination" => "192.0.2.0/24",
             "gateway" => nil,
             "link_id" => interface
           } in routes["items"]

    assert_valid_result("netman.network.routes.list", routes)
  end

  test "connection activation and deactivation return only after convergence" do
    suffix = System.unique_integer([:positive])
    interface = interface("nwc", suffix)
    profile = profile("network-control-#{suffix}", interface)

    MockNetlink.link_up(interface, carrier: true)
    assert :ok = Netman.put_profile(profile.id, profile)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(interface)
      Netman.delete_profile(profile.id)
      MockNetlink.link_removed(interface)
    end)

    payload = %{"profile_id" => profile.id, "interface" => interface}
    assert {:ok, revision} = Network.current("netman.connections.activate", payload)
    context = mutation_context(revision)

    assert {:ok,
            %{
              "profile_id" => profile_id,
              "interface" => ^interface,
              "state" => "activated"
            } = activated} = Network.dispatch("netman.connections.activate", payload, context)

    assert profile_id == profile.id
    assert {:ok, pid} = Connection.Supervisor.find_connection(interface)
    assert {:ok, %{state: :activated, profile_id: ^profile_id}} = Connection.FSM.get_state(pid)
    assert_valid_result("netman.connections.activate", activated)

    assert {:ok, deactivated} =
             Network.dispatch("netman.connections.deactivate", payload, context)

    assert deactivated == %{
             "profile_id" => profile.id,
             "interface" => interface,
             "state" => "deactivated"
           }

    assert {:ok, %{state: :disconnected}} = Connection.FSM.get_state(pid)
    assert_valid_result("netman.connections.deactivate", deactivated)

    assert {:ok, ^deactivated} =
             Network.dispatch("netman.network.connection_state.get", payload)
  end

  test "dispatcher rejects stale revisions and observe-mode mutations before convergence" do
    suffix = System.unique_integer([:positive])
    interface = interface("nwd", suffix)
    profile = profile("network-gate-#{suffix}", interface)

    MockNetlink.link_up(interface, carrier: true)
    assert :ok = Netman.put_profile(profile.id, profile)
    assert {:ok, revision} = Netman.profile_revision(profile.id)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(interface)
      Netman.delete_profile(profile.id)
      MockNetlink.link_removed(interface)
    end)

    payload = %{"profile_id" => profile.id, "interface" => interface}

    assert {:error, %Error{code: :conflict}} =
             Control.dispatch(
               envelope(
                 "netman.connections.activate",
                 payload,
                 String.duplicate("a", 64)
               )
             )

    assert :error = Connection.Supervisor.find_connection(interface)

    :sys.replace_state(RuntimeState, fn state -> %{state | apply_mode: :observe} end)

    assert {:error, %Error{code: :unsupported}} =
             Control.dispatch(envelope("netman.connections.activate", payload, revision))

    assert :error = Connection.Supervisor.find_connection(interface)
  end

  test "maps missing, non-matching, and reconciliation failures to stable errors" do
    suffix = System.unique_integer([:positive])
    missing = interface("nwe", suffix)
    wildcard_id = "network-wildcard-#{suffix}"
    occupied = interface("nwf", suffix)
    owner = profile("network-owner-#{suffix}", occupied)
    contender = profile("network-contender-#{suffix}", occupied)

    assert :ok = Netman.put_profile(owner.id, owner)
    assert :ok = Netman.put_profile(contender.id, contender)
    assert :ok = Netman.put_profile(wildcard_id, %{profile(wildcard_id, nil) | interface: nil})

    missing_profile = profile("network-missing-#{suffix}", missing)
    assert :ok = Netman.put_profile(missing_profile.id, missing_profile)

    loopback = interface("nwg", suffix)
    MockNetlink.link_up(loopback, kind: "loopback")
    MockNetlink.link_up(occupied, carrier: true)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(occupied)

      for id <- [owner.id, contender.id, wildcard_id, missing_profile.id] do
        Netman.delete_profile(id)
      end

      MockNetlink.link_removed(loopback)
      MockNetlink.link_removed(occupied)
    end)

    assert {:ok, missing_revision} = Netman.profile_revision(missing_profile.id)

    assert {:error, %Error{code: :not_found}} =
             Network.dispatch(
               "netman.connections.activate",
               %{"profile_id" => missing_profile.id, "interface" => missing},
               mutation_context(missing_revision)
             )

    assert {:ok, wildcard_revision} = Netman.profile_revision(wildcard_id)

    assert {:error, %Error{code: :apply_failed}} =
             Network.dispatch(
               "netman.connections.activate",
               %{"profile_id" => wildcard_id, "interface" => loopback},
               mutation_context(wildcard_revision)
             )

    assert {:ok, owner_revision} = Netman.profile_revision(owner.id)

    assert {:ok, %{"state" => "activated"}} =
             Network.dispatch(
               "netman.connections.activate",
               %{"profile_id" => owner.id, "interface" => occupied},
               mutation_context(owner_revision)
             )

    assert {:ok, contender_revision} = Netman.profile_revision(contender.id)

    assert {:error, %Error{code: :apply_failed}} =
             Network.dispatch(
               "netman.connections.activate",
               %{"profile_id" => contender.id, "interface" => occupied},
               mutation_context(contender_revision)
             )
  end

  test "checks the profile revision again at the mutation owner boundary" do
    suffix = System.unique_integer([:positive])
    interface = interface("nwh", suffix)
    profile = profile("network-race-#{suffix}", interface)

    MockNetlink.link_up(interface)
    assert :ok = Netman.put_profile(profile.id, profile)
    assert {:ok, stale_revision} = Netman.profile_revision(profile.id)

    assert :ok =
             Netman.put_profile(profile.id, %{profile | autoconnect_priority: 50},
               expected_revision: stale_revision
             )

    on_exit(fn ->
      Connection.Supervisor.stop_connection(interface)
      Netman.delete_profile(profile.id)
      MockNetlink.link_removed(interface)
    end)

    assert {:error, %Error{code: :conflict}} =
             Network.dispatch(
               "netman.connections.activate",
               %{"profile_id" => profile.id, "interface" => interface},
               mutation_context(stale_revision)
             )

    assert :error = Connection.Supervisor.find_connection(interface)
  end

  defp assert_valid_result(operation_name, result) do
    assert {:ok, operation} = NetmanOperation.fetch(operation_name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end

  defp envelope(operation, payload, expected_revision) do
    {:ok, payload_digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: "00000000-0000-0000-0000-000000000301",
      target_type: :netman,
      target_id: "netman-network-test",
      operation: operation,
      idempotency_key: "00000000-0000-0000-0000-000000000302",
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: expected_revision,
      sent_at: @sent_at
    }
  end

  defp mutation_context(revision) do
    %{
      expected_revision: revision,
      current_revision: revision,
      precondition: {:revision, revision},
      config_version: nil
    }
  end

  defp profile(id, interface) do
    %Profile{
      id: id,
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      zone: "default",
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: [], dns_search: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: [], dns_search: []}
    }
  end

  defp interface(prefix, suffix), do: "#{prefix}#{suffix}" |> String.slice(0, 15)

  defp all_features do
    %{
      interfaces: true,
      dhcp_client: true,
      dns_client: true,
      routes: true,
      link_state: true,
      vpn: true
    }
  end
end
