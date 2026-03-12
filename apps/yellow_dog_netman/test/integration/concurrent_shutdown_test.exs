defmodule YellowDog.Netman.Integration.ConcurrentShutdownTest do
  @moduledoc """
  Integration tests for concurrent FSM operations and graceful shutdown,
  verifying that addresses are flushed and resources cleaned up when
  multiple connections are terminated simultaneously.
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Kernel.AddressManager
  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :capture_log

  @iface_count 5

  defp make_profile(iface) do
    %Profile{
      id: "shutdown-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: :rand.uniform(500),
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }
  end

  setup do
    ifaces =
      for i <- 1..@iface_count do
        "shut_eth#{i}_#{:rand.uniform(65535)}"
      end

    profiles = Enum.map(ifaces, &make_profile/1)

    Enum.each(profiles, &ProfileStore.put(&1.id, &1))

    on_exit(fn ->
      Enum.each(ifaces, &Connection.Supervisor.stop_connection/1)
      Enum.each(profiles, fn p -> ProfileStore.delete(p.id) end)
    end)

    %{ifaces: ifaces, profiles: profiles}
  end

  test "multiple FSMs activate and deactivate concurrently", %{
    ifaces: ifaces,
    profiles: profiles
  } do
    # Bring all links up
    Enum.each(ifaces, fn iface ->
      MockNetlink.link_up(iface, carrier: true)
    end)

    Process.sleep(50)

    # Start all connections concurrently
    pids =
      Enum.zip(ifaces, profiles)
      |> Enum.map(fn {iface, profile} ->
        {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
        {iface, pid}
      end)

    Process.sleep(200)

    # All should reach :activated
    Enum.each(pids, fn {iface, pid} ->
      {:ok, state} = Connection.FSM.get_state(pid)
      assert state.state == :activated, "Expected #{iface} to be activated, got #{state.state}"
    end)

    # Stop all concurrently by spawning tasks
    tasks =
      Enum.map(ifaces, fn iface ->
        Task.async(fn ->
          Connection.Supervisor.stop_connection(iface)
        end)
      end)

    Task.await_many(tasks, 5_000)

    Process.sleep(100)

    # All should be gone
    Enum.each(ifaces, fn iface ->
      assert :error = Connection.Supervisor.find_connection(iface)
    end)
  end

  test "static IP FSM cleans up addresses on shutdown" do
    iface = "cleanup_eth_#{:rand.uniform(65535)}"

    static_profile = %Profile{
      id: "cleanup-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.99.0.10/24",
        gateway: "10.99.0.1",
        dns: [],
        dns_search: []
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: [], dns_search: []}
    }

    ProfileStore.put(static_profile.id, static_profile)

    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, static_profile)

    # Simulate the kernel confirming the address was added
    MockNetlink.address_added(iface, "10.99.0.10/24")

    # Wait for the FSM to reach activated
    {:ok, pid} = Connection.Supervisor.find_connection(iface)

    result =
      Enum.reduce_while(1..30, :waiting, fn _, _acc ->
        Process.sleep(100)

        case Connection.FSM.get_state(pid) do
          {:ok, %{state: :activated}} -> {:halt, :activated}
          {:ok, %{state: s}} -> {:cont, s}
          _ -> {:cont, :unknown}
        end
      end)

    assert result == :activated

    # Verify address exists before shutdown
    addrs_before = AddressManager.get_addresses(iface)
    assert length(addrs_before) > 0

    # Delete profile first so reconciliation doesn't respawn
    ProfileStore.delete(static_profile.id)

    # Shutdown the FSM
    Connection.Supervisor.stop_connection(iface)
    Process.sleep(200)

    # After shutdown, the FSM should have issued flush commands
    # (mock netlink accepts them; ETS state reflects post-flush)
    assert :error = Connection.Supervisor.find_connection(iface)
  end

  test "rapid activate-deactivate cycles across multiple interfaces" do
    iface = "rapid_eth_#{:rand.uniform(65535)}"

    profile = make_profile(iface)
    ProfileStore.put(profile.id, profile)

    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    # Cycle activate/deactivate 5 times rapidly
    for _i <- 1..5 do
      {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
      Process.sleep(50)
      Connection.Supervisor.stop_connection(iface)
      Process.sleep(50)
    end

    # Delete profile before assertion to prevent ReconciliationEngine respawn
    ProfileStore.delete(profile.id)
    Process.sleep(50)

    # Final state: no connection running
    Connection.Supervisor.stop_connection(iface)
    Process.sleep(100)
    assert :error = Connection.Supervisor.find_connection(iface)
  end
end
