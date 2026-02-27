defmodule YellowDog.Netman.Connection.SupervisorTest do
  use ExUnit.Case

  alias YellowDog.Netman.Connection.Supervisor, as: ConnSupervisor
  alias YellowDog.Netman.{ProfileStore, Test.MockNetlink}
  alias YellowDog.Netman.Types.Profile

  defp make_profile(iface) do
    id = "sup-test-#{iface}"

    %Profile{
      id: id,
      type: :ethernet,
      interface: iface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }
  end

  test "start_connection starts an FSM for an interface" do
    iface = "sup_start_#{:rand.uniform(65535)}"
    profile = make_profile(iface)
    MockNetlink.link_up(iface, carrier: false)
    Process.sleep(30)

    {:ok, pid} = ConnSupervisor.start_connection(iface, profile)
    assert is_pid(pid)
    assert Process.alive?(pid)

    ConnSupervisor.stop_connection(iface)
  end

  test "start_connection returns existing pid if already started" do
    iface = "sup_dup_#{:rand.uniform(65535)}"
    profile = make_profile(iface)
    MockNetlink.link_up(iface, carrier: false)
    Process.sleep(30)

    {:ok, pid1} = ConnSupervisor.start_connection(iface, profile)
    {:ok, pid2} = ConnSupervisor.start_connection(iface, profile)

    assert pid1 == pid2

    ConnSupervisor.stop_connection(iface)
  end

  test "stop_connection returns :ok for running connection" do
    iface = "sup_stop_#{:rand.uniform(65535)}"
    profile = make_profile(iface)
    MockNetlink.link_up(iface, carrier: false)
    Process.sleep(30)

    {:ok, _pid} = ConnSupervisor.start_connection(iface, profile)
    assert :ok = ConnSupervisor.stop_connection(iface)
    Process.sleep(50)
    assert ConnSupervisor.find_connection(iface) == :error
  end

  test "stop_connection returns error for unknown interface" do
    assert {:error, :not_found} = ConnSupervisor.stop_connection("nonexistent_iface_sup")
  end

  test "find_connection returns error for unknown interface" do
    assert :error = ConnSupervisor.find_connection("no_such_iface_sup")
  end

  test "find_connection_by_profile finds running connection" do
    iface = "sup_by_prof_#{:rand.uniform(65535)}"
    profile = make_profile(iface)
    profile_id = profile.id
    MockNetlink.link_up(iface, carrier: false)
    Process.sleep(30)

    ProfileStore.put(profile_id, profile)
    {:ok, pid} = ConnSupervisor.start_connection(iface, profile)
    Process.sleep(30)

    result = ConnSupervisor.find_connection_by_profile(profile_id)
    assert {:ok, ^pid} = result

    ConnSupervisor.stop_connection(iface)
    ProfileStore.delete(profile_id)
  end

  test "find_connection_by_profile returns :error for unknown profile" do
    assert :error = ConnSupervisor.find_connection_by_profile("no-such-profile-sup")
  end

  test "list_connections includes running FSM states" do
    iface = "sup_list_#{:rand.uniform(65535)}"
    profile = make_profile(iface)
    MockNetlink.link_up(iface, carrier: false)
    Process.sleep(30)

    {:ok, _pid} = ConnSupervisor.start_connection(iface, profile)
    Process.sleep(30)

    connections = ConnSupervisor.list_connections()
    assert is_list(connections)
    assert Enum.any?(connections, &(&1[:interface] == iface))

    ConnSupervisor.stop_connection(iface)
  end

  test "list_connections handles FSM that exits during enumeration" do
    iface = "sup_exit_#{:rand.uniform(65535)}"
    profile = make_profile(iface)
    MockNetlink.link_up(iface, carrier: false)
    Process.sleep(30)

    {:ok, pid} = ConnSupervisor.start_connection(iface, profile)
    Process.sleep(30)

    # Kill the FSM process — list_connections should handle the error gracefully
    Process.exit(pid, :kill)
    Process.sleep(50)

    # Should not crash, returns a list (possibly without the killed connection)
    connections = ConnSupervisor.list_connections()
    assert is_list(connections)
  end
end
