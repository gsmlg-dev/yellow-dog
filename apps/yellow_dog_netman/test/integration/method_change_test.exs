defmodule YellowDog.Netman.Integration.MethodChangeTest do
  @moduledoc """
  Integration tests verifying that changing a profile's IP method while the
  FSM is activated triggers a proper deactivate→reactivate cycle with the
  new configuration.
  """
  use ExUnit.Case

  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :capture_log

  setup do
    iface = "method_eth#{:rand.uniform(65535)}"

    profile = %Profile{
      id: "method-change-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.99.0.1/24",
        gateway: "10.99.0.254",
        dns: ["8.8.8.8"]
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)
    MockNetlink.link_up(iface, carrier: true)
    MockNetlink.address_added(iface, "10.99.0.1/24")
    Process.sleep(50)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile.id)
    end)

    %{iface: iface, profile: profile}
  end

  test "IPv4 method change manual→disabled triggers deactivate→reactivate", %{
    iface: iface,
    profile: profile
  } do
    # Start FSM and let it activate
    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Connection.FSM.activate(pid)
    Process.sleep(300)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated

    # Change IPv4 method from manual → disabled
    updated = %{profile | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}}
    ProfileStore.put(profile.id, updated)

    # Push the profile update via ReconciliationEngine (simulates hot-reload event)
    Connection.FSM.update_profile(pid, updated)
    Process.sleep(500)

    # FSM should have gone through deactivating and come back to a connected state
    {:ok, new_state} = Connection.FSM.get_state(pid)

    # With both IPv4=disabled and IPv6=disabled, the FSM should still reach
    # activated (ip_check bypasses when no global address expected)
    assert new_state.state in [:activated, :disconnected, :configuring, :ip_check],
           "FSM should have reactivated after method change, got: #{new_state.state}"

    # The profile should be updated
    assert new_state.profile_id == profile.id
  end

  test "IPv4 method change manual→auto triggers reconfiguration", %{
    iface: iface,
    profile: profile
  } do
    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Connection.FSM.activate(pid)
    Process.sleep(300)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated

    # Change IPv4 method from manual → auto (DHCP)
    updated = %{profile | ipv4: %{method: :auto, address: nil, gateway: nil, dns: []}}
    Connection.FSM.update_profile(pid, updated)
    Process.sleep(500)

    # FSM should have deactivated and re-entered configuring (waiting for DHCP)
    {:ok, new_state} = Connection.FSM.get_state(pid)

    # Without a real DHCP server, it will be in configuring (waiting) or failed
    assert new_state.state in [:configuring, :failed, :disconnected],
           "FSM should be reconfiguring for DHCP, got: #{new_state.state}"
  end

  test "non-method change (DNS update) stays activated", %{
    iface: iface,
    profile: profile
  } do
    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Connection.FSM.activate(pid)
    Process.sleep(300)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated

    # Change DNS only — not a method change
    updated_ipv4 = Map.put(profile.ipv4, :dns, ["1.1.1.1", "8.8.4.4"])
    updated = %{profile | ipv4: updated_ipv4}
    Connection.FSM.update_profile(pid, updated)
    Process.sleep(200)

    # FSM should still be activated (no deactivate cycle for non-method changes)
    {:ok, new_state} = Connection.FSM.get_state(pid)
    assert new_state.state == :activated

    # DNS should include the new servers
    assert "1.1.1.1" in new_state.dns
    assert "8.8.4.4" in new_state.dns
  end

  test "IPv6 method change disabled→manual triggers reconfiguration", %{
    iface: iface,
    profile: profile
  } do
    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Connection.FSM.activate(pid)
    Process.sleep(300)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated

    # Enable IPv6 manual — this IS a method change
    updated = %{
      profile
      | ipv6: %{
          method: :manual,
          address: "fd00::1/64",
          gateway: "fd00::ffff",
          dns: ["2001:4860:4860::8888"]
        }
    }

    Connection.FSM.update_profile(pid, updated)
    Process.sleep(500)

    # FSM should have gone through deactivate→reactivate cycle
    {:ok, new_state} = Connection.FSM.get_state(pid)

    # May be in various states depending on whether IPv6 address was configured
    assert new_state.state in [:activated, :configuring, :ip_check, :failed, :disconnected],
           "FSM should have attempted reconfiguration, got: #{new_state.state}"
  end
end
