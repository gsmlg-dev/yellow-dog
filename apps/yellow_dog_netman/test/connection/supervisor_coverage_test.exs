defmodule YellowDog.Netman.Connection.SupervisorCoverageTest do
  @moduledoc """
  Tests targeting uncovered branches in Connection.Supervisor:
  - start_connection generic error path
  - list_connections with non-pid child (restarting)
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection.Supervisor, as: ConnSupervisor
  alias YellowDog.Netman.Connection.FSM
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Netman.Test.MockNetlink

  @moduletag :capture_log

  describe "start_connection error handling" do
    test "start_connection with duplicate interface returns existing pid" do
      iface = "supcov_dup_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "supcov-dup-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid1} = ConnSupervisor.start_connection(iface, profile)

      # Starting again returns the same pid via already_started branch
      {:ok, pid2} = ConnSupervisor.start_connection(iface, profile)
      assert pid1 == pid2

      ConnSupervisor.stop_connection(iface)
      MockNetlink.link_removed(iface)
    end
  end

  describe "list_connections with transient child state" do
    test "list_connections handles rapid start/kill without crashing" do
      iface = "supcov_kill_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "supcov-kill-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = ConnSupervisor.start_connection(iface, profile)

      # Kill and immediately list — catches the restarting child case
      Process.exit(pid, :kill)

      # list_connections may encounter a restarting (non-pid) child
      connections = ConnSupervisor.list_connections()
      assert is_list(connections)

      Process.sleep(100)
      ConnSupervisor.stop_connection(iface)
      MockNetlink.link_removed(iface)
    end
  end

  describe "find_connection_by_profile with matched interface" do
    test "find_connection_by_profile delegates to find_connection for matched conn" do
      iface = "supcov_find_#{:rand.uniform(65535)}"
      profile_id = "supcov-find-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = ConnSupervisor.start_connection(iface, profile)
      Process.sleep(30)

      result = ConnSupervisor.find_connection_by_profile(profile_id)
      assert {:ok, ^pid} = result

      ConnSupervisor.stop_connection(iface)
      MockNetlink.link_removed(iface)
    end
  end

  describe "FSM.get_state/1 error handling" do
    test "get_state returns error for stopped process" do
      # Call get_state on a non-existent pid
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      # Process is dead now
      result = FSM.get_state(fake_pid)
      assert {:error, :not_running} = result
    end
  end
end
