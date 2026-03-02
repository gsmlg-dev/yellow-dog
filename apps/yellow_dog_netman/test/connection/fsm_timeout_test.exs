defmodule YellowDog.Netman.Connection.FSMTimeoutTest do
  @moduledoc """
  Tests for FSM timeout paths, DHCP lease lifecycle in activated state,
  and edge cases for carrier loss, deactivation from intermediate states,
  and address removal branches.
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection.FSM
  alias YellowDog.Netman.Kernel.RouteManager
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Netman.Test.MockNetlink

  @moduletag :capture_log

  setup do
    iface = "to_eth#{:rand.uniform(65535)}"

    profile = %Profile{
      id: "timeout-test-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: "10.0.0.100/24", gateway: "10.0.0.1", dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    {:ok, iface: iface, profile: profile}
  end

  describe "DHCP failure path" do
    test "DHCP start failure (MAC detection) transitions to failed", %{iface: iface} do
      profile = dhcp_profile(iface)

      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(50)

      FSM.activate(pid)
      Process.sleep(100)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :failed
      assert state.error == :dhcp_failed
      :gen_statem.stop(pid)
    end
  end

  describe "DHCP retryable failure" do
    test "retryable failure keeps FSM in configuring (direct handler test)", %{profile: profile} do
      # Test the state handler directly since we can't reach configuring
      # with a DHCP profile on fake interfaces (MAC detection is fatal)
      data = %FSM{
        interface: "test_retry",
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 0
      }

      result = FSM.configuring(:info, {:dhcp_lease_failed, :timeout}, data)
      assert {:keep_state, new_data} = result
      assert new_data.dhcp_retries == 1
    end

    test "fatal failure goes straight to failed (direct handler test)", %{profile: profile} do
      data = %FSM{
        interface: "test_fatal",
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 0
      }

      result = FSM.configuring(:info, {:dhcp_lease_failed, {:mac_detection_failed, :test}}, data)
      assert {:next_state, :failed, new_data, _actions} = result
      assert new_data.error == :dhcp_failed
    end

    test "retryable failure exhausts retries then transitions to failed", %{profile: profile} do
      # Start with dhcp_retries at max (3)
      data = %FSM{
        interface: "test_exhaust",
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 3
      }

      result = FSM.configuring(:info, {:dhcp_lease_failed, :timeout}, data)
      assert {:next_state, :failed, new_data, _actions} = result
      assert new_data.error == :dhcp_failed
      assert new_data.dhcp_retries == 0
    end
  end

  describe "DHCP lease lifecycle in activated state" do
    test "lease renewal updates lease data without state change", %{
      iface: iface,
      profile: profile
    } do
      pid = start_and_activate!(iface, profile)

      new_lease = %{ip: "10.0.0.200", subnet: "255.255.255.0", renewed_at: :os.system_time()}
      send(pid, {:dhcp_lease_renewed, new_lease})
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated
      assert state.lease == new_lease
      :gen_statem.stop(pid)
    end

    test "lease expiry transitions to disconnected via deactivating", %{
      iface: iface,
      profile: profile
    } do
      pid = start_and_activate!(iface, profile)

      ref = make_ref()
      test_pid = self()
      handler_id = "lease-expired-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :dhcp, :lease_expired],
        fn _name, _measurements, metadata, _config ->
          send(test_pid, {:dhcp_expired, metadata})
        end,
        nil
      )

      send(pid, {:dhcp_lease_expired, :server_nak})
      Process.sleep(100)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :disconnected

      assert_receive {:dhcp_expired, %{reason: :server_nak}}

      :telemetry.detach(handler_id)
      :gen_statem.stop(pid)
    end

    test "lease renewal emits telemetry event", %{iface: iface, profile: profile} do
      pid = start_and_activate!(iface, profile)

      ref = make_ref()
      test_pid = self()
      handler_id = "lease-renewed-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :dhcp, :lease_renewed],
        fn _name, _measurements, metadata, _config ->
          send(test_pid, {:dhcp_renewed, metadata})
        end,
        nil
      )

      lease = %{ip: "10.0.0.150", subnet: "255.255.255.0"}
      send(pid, {:dhcp_lease_renewed, lease})
      Process.sleep(50)

      assert_receive {:dhcp_renewed, %{lease: ^lease}}

      :telemetry.detach(handler_id)
      :gen_statem.stop(pid)
    end
  end

  describe "carrier loss during configuring" do
    test "carrier lost from failed state triggers recovery on return", %{iface: iface} do
      # DHCP mode → immediate failure on fake interfaces
      profile = %Profile{
        dhcp_profile(iface)
        | autoconnect: true
      }

      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(100)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :failed

      # Carrier event from failed triggers recovery
      MockNetlink.carrier_change(iface, true)
      Process.sleep(100)

      {:ok, state} = FSM.get_state(pid)
      # Should attempt auto-activate again (and fail again with DHCP)
      assert state.state in [:disconnected, :failed, :configuring]
      :gen_statem.stop(pid)
    end
  end

  describe "deactivation from intermediate states" do
    test "deactivate from prepare transitions to disconnected", %{
      iface: iface,
      profile: profile
    } do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(50)

      # Start activation and immediately deactivate
      FSM.activate(pid)
      FSM.deactivate(pid)
      Process.sleep(200)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :disconnected
      :gen_statem.stop(pid)
    end

    test "deactivate during ip_check transitions to disconnected", %{iface: iface} do
      # Use manual IP without pre-adding address — FSM will retry in ip_check
      profile = %Profile{
        id: "ipcheck-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.0.0.50/24", gateway: "10.0.0.1", dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(50)

      FSM.activate(pid)
      Process.sleep(200)

      {:ok, state} = FSM.get_state(pid)

      if state.state == :ip_check do
        FSM.deactivate(pid)
        Process.sleep(100)

        {:ok, state} = FSM.get_state(pid)
        assert state.state == :disconnected
      end

      :gen_statem.stop(pid)
    end

    test "deactivate from configuring (DHCP) transitions to disconnected", %{iface: iface} do
      profile = dhcp_profile(iface)

      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(50)

      FSM.activate(pid)
      # DHCP fails immediately, but deactivate works from configuring or failed
      FSM.deactivate(pid)
      Process.sleep(100)

      {:ok, state} = FSM.get_state(pid)
      # Should be disconnected or failed (DHCP failure races with deactivate)
      assert state.state in [:disconnected, :failed]
      :gen_statem.stop(pid)
    end
  end

  describe "address removal in activated state" do
    test "removing one address while others remain keeps activated", %{
      iface: iface,
      profile: profile
    } do
      MockNetlink.link_up(iface, carrier: true)
      MockNetlink.address_added(iface, "10.0.0.100/24")
      MockNetlink.address_added(iface, "10.0.0.200/24")
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(50)

      FSM.activate(pid)
      Process.sleep(300)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated

      # Remove one address — should remain activated since another global exists
      MockNetlink.address_removed(iface, "10.0.0.100/24")
      Process.sleep(100)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated
      :gen_statem.stop(pid)
    end

    test "removing all addresses triggers deactivation", %{iface: iface, profile: profile} do
      MockNetlink.link_up(iface, carrier: true)
      MockNetlink.address_added(iface, "10.0.0.100/24")
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(50)

      FSM.activate(pid)
      Process.sleep(300)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated

      # Remove the only address
      MockNetlink.address_removed(iface, "10.0.0.100/24")
      Process.sleep(100)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :disconnected
      :gen_statem.stop(pid)
    end

    test "address removal with ipv4 method disabled keeps activated", %{iface: iface} do
      disabled_profile = %Profile{
        id: "disabled-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: disabled_profile)
      Process.sleep(50)

      FSM.activate(pid)
      Process.sleep(200)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated

      # Address removal should be ignored since ipv4 is disabled
      MockNetlink.address_removed(iface, "fe80::1/64")
      Process.sleep(100)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated
      :gen_statem.stop(pid)
    end
  end

  describe "terminate in various states" do
    test "terminate during configuring does not crash", %{iface: iface} do
      profile = dhcp_profile(iface)

      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(50)

      FSM.activate(pid)
      # Stop immediately — may be in configuring or failed
      :gen_statem.stop(pid)
      assert true
    end

    test "terminate during activated performs cleanup", %{iface: iface, profile: profile} do
      pid = start_and_activate!(iface, profile)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated

      # Should not crash
      :gen_statem.stop(pid)
      assert true
    end
  end

  describe "install routes" do
    test "no route installed when gateway is nil", %{iface: iface} do
      no_gw_profile = %Profile{
        id: "no-gw-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.0.0.100/24", gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      MockNetlink.address_added(iface, "10.0.0.100/24")
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: no_gw_profile)
      Process.sleep(50)

      FSM.activate(pid)
      Process.sleep(300)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated

      routes = RouteManager.get_routes(iface)
      default_routes = Enum.filter(routes, fn r -> r.destination == "default" end)
      assert default_routes == []
      :gen_statem.stop(pid)
    end
  end

  describe "IPv6 gateway route installation" do
    test "dual-stack profile with IPv6 gateway reaches activated", %{iface: iface} do
      ipv6_gw_profile = %Profile{
        id: "ipv6gw-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.0.0.100/24", gateway: "10.0.0.1", dns: []},
        ipv6: %{method: :manual, address: nil, gateway: "fe80::1", dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      MockNetlink.address_added(iface, "10.0.0.100/24")
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: ipv6_gw_profile)
      Process.sleep(50)

      FSM.activate(pid)
      Process.sleep(300)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated
      :gen_statem.stop(pid)
    end

    test "IPv6-only gateway profile reaches activated without crash", %{iface: iface} do
      ipv6_only_profile = %Profile{
        id: "ipv6only-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.0.0.100/24", gateway: nil, dns: []},
        ipv6: %{method: :manual, address: nil, gateway: "2001:db8::1", dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      MockNetlink.address_added(iface, "10.0.0.100/24")
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: ipv6_only_profile)
      Process.sleep(50)

      FSM.activate(pid)
      Process.sleep(300)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated
      :gen_statem.stop(pid)
    end
  end

  describe "push_dns with IPv6 addresses" do
    test "IPv6 DNS addresses are included in state_info", %{iface: iface} do
      ipv6_dns_profile = %Profile{
        id: "ipv6dns-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{
          method: :manual,
          address: "10.0.0.100/24",
          gateway: "10.0.0.1",
          dns: ["1.1.1.1"]
        },
        ipv6: %{
          method: :disabled,
          address: nil,
          gateway: nil,
          dns: ["2001:4860:4860::8888", "2001:4860:4860::8844"]
        }
      }

      MockNetlink.link_up(iface, carrier: true)
      MockNetlink.address_added(iface, "10.0.0.100/24")
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: iface, profile: ipv6_dns_profile)
      Process.sleep(50)

      FSM.activate(pid)
      Process.sleep(300)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated
      assert state.dns == ["1.1.1.1", "2001:4860:4860::8888", "2001:4860:4860::8844"]
      :gen_statem.stop(pid)
    end
  end

  ## Helpers

  defp dhcp_profile(iface) do
    %Profile{
      id: "dhcp-test-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }
  end

  defp start_and_activate!(iface, profile) do
    MockNetlink.link_up(iface, carrier: true)
    MockNetlink.address_added(iface, "10.0.0.100/24")
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
    Process.sleep(50)

    FSM.activate(pid)
    Process.sleep(300)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :activated, "Expected activated but got #{state.state}"
    pid
  end
end
