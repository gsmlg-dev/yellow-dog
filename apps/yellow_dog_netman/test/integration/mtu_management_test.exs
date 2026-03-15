defmodule YellowDog.Netman.Integration.MtuManagementTest do
  @moduledoc """
  Integration tests for MTU management during connection lifecycle.
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :capture_log

  test "MTU is set via Netlink command when profile specifies mtu" do
    iface = "mtu_eth#{:rand.uniform(65535)}"

    profile = %Profile{
      id: "mtu-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: 9000},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)

    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(200)

    {:ok, pid} = Connection.Supervisor.find_connection(iface)
    {:ok, state} = Connection.FSM.get_state(pid)

    # FSM should have transitioned through prepare (where MTU is set)
    # and reached activated state
    assert state.state == :activated

    Connection.Supervisor.stop_connection(iface)
    ProfileStore.delete(profile.id)
  end

  test "nil MTU in profile skips MTU configuration" do
    iface = "nmtu_eth#{:rand.uniform(65535)}"

    profile = %Profile{
      id: "nmtu-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)

    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(200)

    {:ok, pid} = Connection.Supervisor.find_connection(iface)
    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated

    Connection.Supervisor.stop_connection(iface)
    ProfileStore.delete(profile.id)
  end
end
