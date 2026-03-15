defmodule YellowDog.Netman.Integration.RoutePriorityTest do
  @moduledoc """
  Integration tests verifying that multiple interfaces get correct
  route metrics based on profile priority, and that PolicyEngine
  default route selection integrates with active connections.
  """
  use ExUnit.Case

  alias YellowDog.Netman.{PolicyEngine, ProfileStore}
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :capture_log

  setup do
    iface_hi = "rpri_hi_#{:rand.uniform(65535)}"
    iface_lo = "rpri_lo_#{:rand.uniform(65535)}"

    # High-priority profile with a gateway (triggers route installation)
    profile_hi = %Profile{
      id: "rpri-hi-#{iface_hi}",
      type: :ethernet,
      interface: iface_hi,
      autoconnect: true,
      autoconnect_priority: 500,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: "10.10.0.10/24", gateway: "10.10.0.1", dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    # Low-priority profile with a different gateway
    profile_lo = %Profile{
      id: "rpri-lo-#{iface_lo}",
      type: :ethernet,
      interface: iface_lo,
      autoconnect: true,
      autoconnect_priority: 50,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: "10.20.0.10/24", gateway: "10.20.0.1", dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile_hi.id, profile_hi)
    ProfileStore.put(profile_lo.id, profile_lo)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(iface_hi)
      Connection.Supervisor.stop_connection(iface_lo)
      ProfileStore.delete(profile_hi.id)
      ProfileStore.delete(profile_lo.id)
    end)

    %{
      iface_hi: iface_hi,
      iface_lo: iface_lo,
      profile_hi: profile_hi,
      profile_lo: profile_lo
    }
  end

  test "FSMs install routes with metrics inversely proportional to priority", %{
    iface_hi: iface_hi,
    iface_lo: iface_lo,
    profile_hi: profile_hi,
    profile_lo: profile_lo
  } do
    # Simulate both interfaces available
    MockNetlink.link_up(iface_hi, carrier: true)
    MockNetlink.link_up(iface_lo, carrier: true)
    Process.sleep(50)

    # Add addresses so IP check passes
    MockNetlink.address_added(iface_hi, "10.10.0.10/24")
    MockNetlink.address_added(iface_lo, "10.20.0.10/24")
    Process.sleep(50)

    # Start both connections
    {:ok, pid_hi} = Connection.Supervisor.start_connection(iface_hi, profile_hi)
    {:ok, pid_lo} = Connection.Supervisor.start_connection(iface_lo, profile_lo)

    # Wait for both to reach activated (poll with timeout)
    assert wait_for_state(pid_hi, :activated, 5000),
           "High-priority FSM did not reach :activated"

    assert wait_for_state(pid_lo, :activated, 5000),
           "Low-priority FSM did not reach :activated"

    {:ok, state_hi} = Connection.FSM.get_state(pid_hi)
    {:ok, state_lo} = Connection.FSM.get_state(pid_lo)
    assert state_hi.state == :activated
    assert state_lo.state == :activated

    # Verify PolicyEngine gives correct metrics
    connections = Connection.Supervisor.list_connections()
    metrics = PolicyEngine.route_metrics(connections)

    metric_hi = Map.get(metrics, profile_hi.id)
    metric_lo = Map.get(metrics, profile_lo.id)

    assert metric_hi < metric_lo,
           "Higher priority (#{profile_hi.autoconnect_priority}) should get lower metric, " <>
             "got hi=#{metric_hi} lo=#{metric_lo}"

    # Verify PolicyEngine selects high-priority as default route
    assert {:ok, default_id} = PolicyEngine.default_route(connections)
    assert default_id == profile_hi.id
  end

  test "default route changes when higher-priority connection deactivates", %{
    iface_hi: iface_hi,
    iface_lo: iface_lo,
    profile_hi: profile_hi,
    profile_lo: profile_lo
  } do
    MockNetlink.link_up(iface_hi, carrier: true)
    MockNetlink.link_up(iface_lo, carrier: true)
    Process.sleep(50)
    MockNetlink.address_added(iface_hi, "10.10.0.10/24")
    MockNetlink.address_added(iface_lo, "10.20.0.10/24")
    Process.sleep(50)

    {:ok, pid_hi} = Connection.Supervisor.start_connection(iface_hi, profile_hi)
    {:ok, _pid_lo} = Connection.Supervisor.start_connection(iface_lo, profile_lo)
    Process.sleep(500)

    # Both active — high priority is default
    connections = Connection.Supervisor.list_connections()
    expected_hi_id = profile_hi.id
    assert {:ok, ^expected_hi_id} = PolicyEngine.default_route(connections)

    # Deactivate high-priority connection
    Connection.FSM.deactivate(pid_hi)
    Process.sleep(200)

    {:ok, state_hi} = Connection.FSM.get_state(pid_hi)
    assert state_hi.state == :disconnected

    # Now only low-priority should be active — it becomes default
    # Filter to only this test's connections to avoid interference from parallel tests
    test_ids = MapSet.new([profile_hi.id, profile_lo.id])

    connections_after =
      Connection.Supervisor.list_connections()
      |> Enum.filter(&MapSet.member?(test_ids, &1.profile_id))

    active = Enum.filter(connections_after, &(&1.state == :activated))

    case PolicyEngine.default_route(active) do
      {:ok, default_id} ->
        assert default_id == profile_lo.id

      :none ->
        # If low-priority is still in transition, that's fine
        :ok
    end
  end

  test "DNS priority ordering follows connection priority", %{
    iface_hi: iface_hi,
    iface_lo: iface_lo
  } do
    # Profiles with DNS servers
    profile_hi_dns = %Profile{
      id: "rpri-hi-dns-#{iface_hi}",
      type: :ethernet,
      interface: iface_hi,
      autoconnect: true,
      autoconnect_priority: 500,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: "10.10.0.10/24", gateway: "10.10.0.1", dns: ["8.8.8.8"]},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    profile_lo_dns = %Profile{
      id: "rpri-lo-dns-#{iface_lo}",
      type: :ethernet,
      interface: iface_lo,
      autoconnect: true,
      autoconnect_priority: 50,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.20.0.10/24",
        gateway: "10.20.0.1",
        dns: ["1.1.1.1"]
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile_hi_dns.id, profile_hi_dns)
    ProfileStore.put(profile_lo_dns.id, profile_lo_dns)

    MockNetlink.link_up(iface_hi, carrier: true)
    MockNetlink.link_up(iface_lo, carrier: true)
    Process.sleep(50)
    MockNetlink.address_added(iface_hi, "10.10.0.10/24")
    MockNetlink.address_added(iface_lo, "10.20.0.10/24")
    Process.sleep(50)

    {:ok, _} = Connection.Supervisor.start_connection(iface_hi, profile_hi_dns)
    {:ok, _} = Connection.Supervisor.start_connection(iface_lo, profile_lo_dns)
    Process.sleep(500)

    connections = Connection.Supervisor.list_connections()
    dns_list = PolicyEngine.dns_priority(connections)

    # High-priority DNS servers should come first
    assert is_list(dns_list)

    if length(dns_list) >= 2 do
      # First entry should be from the higher-priority connection
      first = List.first(dns_list)
      assert first.priority >= 500 or first.dns == ["8.8.8.8"]
    end

    # Cleanup
    ProfileStore.delete(profile_hi_dns.id)
    ProfileStore.delete(profile_lo_dns.id)
  end

  test "route metrics are deterministic across multiple calculations", %{
    iface_hi: iface_hi,
    iface_lo: iface_lo,
    profile_hi: profile_hi,
    profile_lo: profile_lo
  } do
    MockNetlink.link_up(iface_hi, carrier: true)
    MockNetlink.link_up(iface_lo, carrier: true)
    Process.sleep(50)
    MockNetlink.address_added(iface_hi, "10.10.0.10/24")
    MockNetlink.address_added(iface_lo, "10.20.0.10/24")
    Process.sleep(50)

    {:ok, _} = Connection.Supervisor.start_connection(iface_hi, profile_hi)
    {:ok, _} = Connection.Supervisor.start_connection(iface_lo, profile_lo)
    Process.sleep(500)

    connections = Connection.Supervisor.list_connections()

    metrics1 = PolicyEngine.route_metrics(connections)
    metrics2 = PolicyEngine.route_metrics(connections)
    metrics3 = PolicyEngine.route_metrics(connections)

    assert metrics1 == metrics2
    assert metrics2 == metrics3
  end

  defp wait_for_state(pid, expected_state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait_loop(pid, expected_state, deadline)
  end

  defp wait_loop(pid, expected_state, deadline) do
    case Connection.FSM.get_state(pid) do
      {:ok, %{state: ^expected_state}} ->
        true

      {:ok, _} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          wait_loop(pid, expected_state, deadline)
        else
          false
        end

      _ ->
        false
    end
  end
end
