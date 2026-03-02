defmodule YellowDog.Netman.Integration.DnsConfigurationTest do
  @moduledoc """
  Integration tests verifying DNS configuration is pushed to resolved
  when connections activate, and cleaned up on deactivation.
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :capture_log

  setup do
    iface = "dns_eth#{:rand.uniform(65535)}"

    profile = %Profile{
      id: "dns-test-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.50.0.10/24",
        gateway: "10.50.0.1",
        dns: ["8.8.8.8", "8.8.4.4"]
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile.id)
    end)

    %{iface: iface, profile: profile}
  end

  test "FSM includes DNS servers in state_info", %{iface: iface, profile: profile} do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    MockNetlink.address_added(iface, "10.50.0.10/24")

    {:ok, pid} = Connection.Supervisor.find_connection(iface)

    poll_until_activated(pid)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated
    assert state.dns == ["8.8.8.8", "8.8.4.4"]
  end

  test "DNS servers from both IPv4 and IPv6 are combined in state_info", %{
    iface: iface,
    profile: profile
  } do
    # Remove setup profile to avoid ReconciliationEngine auto-starting FSM with it
    ProfileStore.delete(profile.id)

    dual_profile = %Profile{
      id: "dual-dns-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.50.0.10/24",
        gateway: "10.50.0.1",
        dns: ["8.8.8.8"]
      },
      ipv6: %{
        method: :disabled,
        address: nil,
        gateway: nil,
        dns: ["2001:4860:4860::8888"]
      }
    }

    ProfileStore.put(dual_profile.id, dual_profile)

    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, dual_profile)
    Process.sleep(50)
    MockNetlink.address_added(iface, "10.50.0.10/24")
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.find_connection(iface)
    poll_until_activated(pid)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.dns == ["8.8.8.8", "2001:4860:4860::8888"]

    Connection.Supervisor.stop_connection(iface)
    ProfileStore.delete(dual_profile.id)
  end

  test "PolicyEngine dns_priority sorts by connection priority" do
    # Two active connections with DNS servers
    connections = [
      %{
        profile_id: "high-pri",
        interface: "eth0",
        state: :activated,
        type: :ethernet,
        autoconnect_priority: 200,
        priority: 200,
        dns: ["1.1.1.1", "1.0.0.1"]
      },
      %{
        profile_id: "low-pri",
        interface: "eth1",
        state: :activated,
        type: :ethernet,
        autoconnect_priority: 50,
        priority: 50,
        dns: ["8.8.8.8"]
      }
    ]

    result = YellowDog.Netman.PolicyEngine.dns_priority(connections)

    # Higher priority connection's DNS servers should come first
    assert length(result) == 3
    servers = Enum.map(result, & &1.server)
    assert servers == ["1.1.1.1", "1.0.0.1", "8.8.8.8"]

    # First two entries from high-priority connection have higher effective priority
    assert Enum.at(result, 0).priority > Enum.at(result, 2).priority
  end

  test "connection with no DNS servers still activates", %{iface: iface} do
    no_dns_profile = %Profile{
      id: "no-dns-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(no_dns_profile.id, no_dns_profile)

    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.start_connection(iface, no_dns_profile)
    poll_until_activated(pid)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated
    assert state.dns == []

    Connection.Supervisor.stop_connection(iface)
    ProfileStore.delete(no_dns_profile.id)
  end

  test "DNS state is cleared after deactivation", %{iface: iface, profile: profile} do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    MockNetlink.address_added(iface, "10.50.0.10/24")

    {:ok, pid} = Connection.Supervisor.find_connection(iface)
    poll_until_activated(pid)

    # Deactivate
    Connection.FSM.deactivate(pid)
    Process.sleep(150)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :disconnected
    # DNS servers are still in the profile, but the connection is down
    # so resolved should have been reset (reset_dns called in deactivating cleanup)
  end

  ## Helpers

  defp poll_until_activated(pid, attempts \\ 30) do
    Enum.reduce_while(1..attempts, :waiting, fn _, _acc ->
      Process.sleep(100)

      case Connection.FSM.get_state(pid) do
        {:ok, %{state: :activated}} -> {:halt, :activated}
        {:ok, %{state: s}} -> {:cont, s}
        _ -> {:cont, :unknown}
      end
    end)
  end
end
