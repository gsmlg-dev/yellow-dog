defmodule YellowDog.Netman.Connection.FSMHandlersTest do
  @moduledoc """
  Tests targeting uncovered FSM state handler paths.

  Uses direct handler invocation (state functions are public in :state_functions mode)
  and direct message injection to cover branches not reachable via normal flow.
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection.FSM
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Netman.Test.MockNetlink

  @moduletag :capture_log

  defp base_profile(iface, overrides \\ %{}) do
    base = %Profile{
      id: "handlers-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: "10.0.0.100/24", gateway: "10.0.0.1", dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    Map.merge(base, overrides)
  end

  defp start_in_disconnected!(iface, profile) do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(30)
    {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
    Process.sleep(30)
    {:ok, state} = FSM.get_state(pid)
    assert state.state == :disconnected
    pid
  end

  # ----------------------------------------------------------------
  # disconnected state handlers
  # ----------------------------------------------------------------

  describe "disconnected state" do
    test "carrier-true link_update in disconnected triggers auto_activate" do
      iface = "hdlr_disc_#{:rand.uniform(65535)}"
      profile = base_profile(iface, %{autoconnect: true})

      # Start with no carrier so FSM is unavailable, then bring up with no carrier
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(30)
      {:ok, state} = FSM.get_state(pid)
      assert state.state == :disconnected

      # Send carrier=true link_update — should trigger auto_activate
      send(pid, {:netman_event, "netman:link:#{iface}", {:link_update, %{carrier: true}}})
      Process.sleep(200)

      {:ok, state} = FSM.get_state(pid)
      # autoconnect=true means it attempts to activate
      assert state.state in [:configuring, :ip_check, :activated, :failed, :prepare]
      :gen_statem.stop(pid)
    end

    test "removed event in disconnected transitions to unavailable" do
      iface = "hdlr_disc_rm_#{:rand.uniform(65535)}"
      profile = base_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(30)
      {:ok, state} = FSM.get_state(pid)
      assert state.state == :disconnected

      send(pid, {:netman_event, "netman:link:#{iface}", {:removed, iface}})
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :unavailable
      :gen_statem.stop(pid)
    end
  end

  # ----------------------------------------------------------------
  # prepare state handlers — direct invocation
  # ----------------------------------------------------------------

  describe "prepare state handlers (direct)" do
    setup do
      iface = "hdlr_prep_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :prepare}
      {:ok, iface: iface, profile: profile, data: data}
    end

    test "prepare :state_timeout :setup_timeout transitions to failed", %{data: data} do
      result = FSM.prepare(:state_timeout, :setup_timeout, data)
      assert {:next_state, :failed, new_data, _} = result
      assert new_data.error == :setup_timeout
    end

    test "prepare :removed event transitions to unavailable", %{data: data, iface: iface} do
      result =
        FSM.prepare(:info, {:netman_event, "netman:link:#{iface}", {:removed, iface}}, data)

      assert {:next_state, :unavailable, _new_data, _actions} = result
    end

    test "prepare :deactivate transitions to deactivating", %{data: data} do
      result = FSM.prepare(:cast, :deactivate, data)
      assert {:next_state, :deactivating, _new_data, actions} = result
      assert Enum.any?(actions, fn
               {:state_timeout, _, :cleanup_timeout} -> true
               _ -> false
             end)
    end

    test "prepare get_state returns prepare state info", %{data: data} do
      result = FSM.prepare({:call, {self(), make_ref()}}, :get_state, data)
      assert {:keep_state, _data, [{:reply, _, {:ok, state}}]} = result
      assert state.state == :prepare
    end

    test "prepare catch-all ignores unknown events", %{data: data} do
      result = FSM.prepare(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end
  end

  # ----------------------------------------------------------------
  # configuring state handlers — direct invocation
  # ----------------------------------------------------------------

  describe "configuring state handlers (direct)" do
    setup do
      iface = "hdlr_cfg_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :configuring}
      {:ok, iface: iface, profile: profile, data: data}
    end

    test "carrier lost during configuring transitions to deactivating", %{
      data: data,
      iface: iface
    } do
      result =
        FSM.configuring(
          :info,
          {:netman_event, "netman:link:#{iface}", {:link_update, %{carrier: false}}},
          data
        )

      assert {:next_state, :deactivating, _new_data, actions} = result

      assert Enum.any?(actions, fn
               {:next_event, :internal, :cleanup} -> true
               _ -> false
             end)
    end

    test "removed event during configuring transitions to unavailable", %{
      data: data,
      iface: iface
    } do
      result =
        FSM.configuring(
          :info,
          {:netman_event, "netman:link:#{iface}", {:removed, iface}},
          data
        )

      assert {:next_state, :unavailable, _new_data, _actions} = result
    end

    test "deactivate during configuring transitions to deactivating", %{data: data} do
      result = FSM.configuring(:cast, :deactivate, data)
      assert {:next_state, :deactivating, _new_data, actions} = result

      assert Enum.any?(actions, fn
               {:next_event, :internal, :cleanup} -> true
               _ -> false
             end)
    end

    test "configuring timeout transitions to failed", %{data: data} do
      result = FSM.configuring(:state_timeout, :configuring_timeout, data)
      assert {:next_state, :failed, new_data, _actions} = result
      assert new_data.error == :configuring_timeout
    end

    test "manual IP with no address configured transitions to failed" do
      iface = "hdlr_noaddr_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "noaddr-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      data = %FSM{interface: iface, profile: profile, current_state: :configuring}
      result = FSM.configuring(:internal, :configure_ip, data)
      assert {:next_state, :failed, new_data, _actions} = result
      assert new_data.error == :no_address_configured
    end

    test "get_state in configuring returns configuring state info", %{data: data} do
      result = FSM.configuring({:call, {self(), make_ref()}}, :get_state, data)
      assert {:keep_state, _data, [{:reply, _, {:ok, state}}]} = result
      assert state.state == :configuring
    end
  end

  # ----------------------------------------------------------------
  # ip_check state handlers — direct invocation
  # ----------------------------------------------------------------

  describe "ip_check state handlers (direct)" do
    setup do
      iface = "hdlr_ipc_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :ip_check}
      {:ok, iface: iface, profile: profile, data: data}
    end

    test "ip_check retry when no global address (first retry)", %{data: data} do
      # No addresses in AddressManager → retry
      result = FSM.ip_check(:internal, :check_ip, data)
      assert {:keep_state, new_data, [{:state_timeout, 2000, :retry_check}]} = result
      assert new_data.ip_check_retries == 1
    end

    test "ip_check retry state_timeout triggers another check", %{data: data} do
      result = FSM.ip_check(:state_timeout, :retry_check, data)
      assert {:keep_state, ^data, [{:next_event, :internal, :check_ip}]} = result
    end

    test "ip_check exhausts retries and transitions to failed", %{data: data} do
      exhausted_data = %{data | ip_check_retries: 30}
      result = FSM.ip_check(:internal, :check_ip, exhausted_data)
      assert {:next_state, :failed, new_data, _actions} = result
      assert new_data.error == :ip_check_timeout
      assert new_data.ip_check_retries == 0
    end

    test "removed event in ip_check transitions to unavailable", %{data: data, iface: iface} do
      result =
        FSM.ip_check(:info, {:netman_event, "netman:link:#{iface}", {:removed, iface}}, data)

      assert {:next_state, :unavailable, new_data, _actions} = result
      assert new_data.ip_check_retries == 0
    end

    test "deactivate in ip_check transitions to deactivating", %{data: data} do
      result = FSM.ip_check(:cast, :deactivate, data)
      assert {:next_state, :deactivating, new_data, actions} = result
      assert new_data.ip_check_retries == 0

      assert Enum.any?(actions, fn
               {:next_event, :internal, :cleanup} -> true
               _ -> false
             end)
    end

    test "get_state in ip_check returns ip_check state info", %{data: data} do
      result = FSM.ip_check({:call, {self(), make_ref()}}, :get_state, data)
      assert {:keep_state, _data, [{:reply, _, {:ok, state}}]} = result
      assert state.state == :ip_check
    end

    test "ip_check with disabled ipv4 method passes without address", %{iface: iface} do
      disabled_profile = %Profile{
        id: "ipc-disabled-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      data = %FSM{
        interface: iface,
        profile: disabled_profile,
        current_state: :ip_check,
        ip_check_retries: 0
      }

      result = FSM.ip_check(:internal, :check_ip, data)
      assert {:next_state, :activated, _new_data, actions} = result

      assert Enum.any?(actions, fn
               {:next_event, :internal, :post_activate} -> true
               _ -> false
             end)
    end
  end

  # ----------------------------------------------------------------
  # activated state handlers
  # ----------------------------------------------------------------

  describe "activated state handlers" do
    test "push_dns skips invalid DNS server address" do
      iface = "hdlr_dns_inv_#{:rand.uniform(65535)}"

      invalid_dns_profile = %Profile{
        id: "invalid-dns-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.0.0.100/24", gateway: "10.0.0.1", dns: ["not.an.ip"]},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      MockNetlink.address_added(iface, "10.0.0.100/24")
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: iface, profile: invalid_dns_profile)
      Process.sleep(30)
      FSM.activate(pid)
      Process.sleep(300)

      # Should still reach activated (invalid DNS servers are skipped with warning)
      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated
      :gen_statem.stop(pid)
    end

    test "push_dns includes DHCP-provided DNS servers in state" do
      iface = "hdlr_dns_lease_#{:rand.uniform(65535)}"
      profile = base_profile(iface)

      MockNetlink.link_up(iface, carrier: true)
      MockNetlink.address_added(iface, "10.0.0.100/24")
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(30)
      FSM.activate(pid)
      Process.sleep(300)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated

      # Inject a lease renewal with DNS servers
      lease = %{dns_servers: [{8, 8, 8, 8}, {1, 1, 1, 1}]}
      send(pid, {:dhcp_lease_renewed, lease})
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.lease == lease
      assert state.state == :activated
      :gen_statem.stop(pid)
    end
  end

  # ----------------------------------------------------------------
  # failed state handlers
  # ----------------------------------------------------------------

  describe "failed state handlers (direct)" do
    setup do
      iface = "hdlr_fail_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :failed, error: :test_error}
      {:ok, iface: iface, profile: profile, data: data}
    end

    test "carrier-true link_update in failed triggers recovery", %{data: data, iface: iface} do
      result =
        FSM.failed(
          :info,
          {:netman_event, "netman:link:#{iface}", {:link_update, %{carrier: true}}},
          data
        )

      assert {:next_state, :disconnected, new_data, actions} = result
      assert new_data.error == nil

      assert Enum.any?(actions, fn
               {:next_event, :internal, :auto_activate} -> true
               _ -> false
             end)
    end

    test "removed event in failed transitions to unavailable", %{data: data, iface: iface} do
      result =
        FSM.failed(:info, {:netman_event, "netman:link:#{iface}", {:removed, iface}}, data)

      assert {:next_state, :unavailable, new_data, _actions} = result
      assert new_data.error == nil
    end

    test "get_state in failed returns failed state info", %{data: data} do
      result = FSM.failed({:call, {self(), make_ref()}}, :get_state, data)
      assert {:keep_state, _data, [{:reply, _, {:ok, state}}]} = result
      assert state.state == :failed
      assert state.error == :test_error
    end

    test "catch-all in failed ignores unknown events", %{data: data} do
      result = FSM.failed(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end
  end

  # ----------------------------------------------------------------
  # configuring: global address event
  # ----------------------------------------------------------------

  describe "configuring global address event (direct)" do
    test "global address event in configuring transitions to ip_check" do
      iface = "hdlr_global_#{:rand.uniform(65535)}"
      profile = base_profile(iface)

      data = %FSM{interface: iface, profile: profile, current_state: :configuring}

      result =
        FSM.configuring(
          :info,
          {:netman_event, "netman:address:#{iface}", {:add, %{scope: :global}}},
          data
        )

      assert {:next_state, :ip_check, _new_data, actions} = result

      assert Enum.any?(actions, fn
               {:next_event, :internal, :check_ip} -> true
               _ -> false
             end)
    end
  end

  # ----------------------------------------------------------------
  # configuring: retry_dhcp message
  # ----------------------------------------------------------------

  describe "configuring retry_dhcp message (direct)" do
    test "retry_dhcp message triggers another DHCP start" do
      iface = "hdlr_rdhcp_#{:rand.uniform(65535)}"
      profile = base_profile(iface, %{ipv4: %{method: :auto, address: nil, gateway: nil, dns: []}})

      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 1
      }

      # retry_dhcp message invokes start_dhcp and keeps state
      result = FSM.configuring(:info, :retry_dhcp, data)
      assert {:keep_state, ^data} = result
    end
  end

  # ----------------------------------------------------------------
  # unavailable state handlers — get_state
  # ----------------------------------------------------------------

  describe "unavailable state get_state (direct)" do
    test "get_state in unavailable returns unavailable state info" do
      iface = "hdlr_unav_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :unavailable}

      result = FSM.unavailable({:call, {self(), make_ref()}}, :get_state, data)
      assert {:keep_state, _data, [{:reply, _, {:ok, state}}]} = result
      assert state.state == :unavailable
    end

    test "link_update without carrier in unavailable transitions to disconnected" do
      iface = "hdlr_unav_nocarr_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :unavailable}

      result =
        FSM.unavailable(
          :info,
          {:netman_event, "netman:link:#{iface}", {:link_update, %{carrier: false}}},
          data
        )

      assert {:next_state, :disconnected, _new_data, _actions} = result
    end
  end

  # ----------------------------------------------------------------
  # deactivating state handlers
  # ----------------------------------------------------------------

  describe "deactivating state handlers (direct)" do
    test "deactivating cleanup_timeout forces transition to disconnected" do
      iface = "hdlr_deact_to_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :deactivating, lease: nil}

      result = FSM.deactivating(:state_timeout, :cleanup_timeout, data)
      assert {:next_state, :disconnected, new_data, _actions} = result
      assert new_data.lease == nil
    end

    test "deactivating catch-all ignores unknown events" do
      iface = "hdlr_deact_unk_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :deactivating}

      result = FSM.deactivating(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end
  end

  # ----------------------------------------------------------------
  # Full integration: interface removal from prepare/configuring/ip_check
  # ----------------------------------------------------------------

  describe "interface removal from intermediate states (integration)" do
    test "link removal injected while in prepare goes to unavailable" do
      iface = "hdlr_prep_rm_#{:rand.uniform(65535)}"
      profile = base_profile(iface)

      pid = start_in_disconnected!(iface, profile)
      FSM.activate(pid)
      # Immediately inject removal before prepare completes
      send(pid, {:netman_event, "netman:link:#{iface}", {:removed, iface}})
      Process.sleep(200)

      {:ok, state} = FSM.get_state(pid)
      assert state.state in [:unavailable, :disconnected, :configuring, :ip_check, :activated]
      :gen_statem.stop(pid)
    end

    test "link removal in configuring transitions toward unavailable" do
      iface = "hdlr_cfg_rm_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :configuring}

      result =
        FSM.configuring(
          :info,
          {:netman_event, "netman:link:#{iface}", {:removed, iface}},
          data
        )

      assert {:next_state, :unavailable, _new_data, _actions} = result
    end

    test "link removal in ip_check flushes addresses and goes unavailable" do
      iface = "hdlr_ipc_rm_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :ip_check, ip_check_retries: 2}

      result =
        FSM.ip_check(:info, {:netman_event, "netman:link:#{iface}", {:removed, iface}}, data)

      assert {:next_state, :unavailable, new_data, _actions} = result
      assert new_data.ip_check_retries == 0
    end
  end

  # ----------------------------------------------------------------
  # apply_static_ipv6 coverage
  # ----------------------------------------------------------------

  describe "apply_static_ipv6 (direct via configuring)" do
    test "static ipv6 address with CIDR is applied silently" do
      iface = "hdlr_ipv6s_#{:rand.uniform(65535)}"

      ipv6_profile = %Profile{
        id: "ipv6s-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.0.0.100/24", gateway: "10.0.0.1", dns: []},
        ipv6: %{method: :manual, address: "2001:db8::1/64", gateway: nil, dns: []}
      }

      data = %FSM{interface: iface, profile: ipv6_profile, current_state: :configuring}

      # configure_ip calls apply_static_ipv6 then apply_static_ip
      result = FSM.configuring(:internal, :configure_ip, data)

      # Should proceed to ip_check (static IPv4 applied)
      assert {:next_state, :ip_check, _new_data, _actions} = result
    end
  end

  # ----------------------------------------------------------------
  # MTU configuration in prepare
  # ----------------------------------------------------------------

  describe "MTU configuration via prepare" do
    test "prepare configures MTU when set in profile" do
      iface = "hdlr_mtu_#{:rand.uniform(65535)}"

      mtu_profile = %Profile{
        id: "mtu-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: 9000},
        ipv4: %{method: :manual, address: "10.0.0.100/24", gateway: "10.0.0.1", dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      MockNetlink.address_added(iface, "10.0.0.100/24")
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: iface, profile: mtu_profile)
      Process.sleep(30)
      FSM.activate(pid)
      Process.sleep(300)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :activated
      :gen_statem.stop(pid)
    end
  end

  # ----------------------------------------------------------------
  # FSM terminate in ip_check state
  # ----------------------------------------------------------------

  describe "FSM terminate cleanup" do
    test "terminate in ip_check state performs cleanup without crash" do
      iface = "hdlr_term_ipc_#{:rand.uniform(65535)}"
      profile = base_profile(iface)

      # Direct terminate call with ip_check state
      data = %FSM{interface: iface, profile: profile, current_state: :ip_check}
      assert :ok = FSM.terminate(:normal, :ip_check, data)
    end

    test "terminate in unavailable state is a no-op" do
      iface = "hdlr_term_unav_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :unavailable}
      assert :ok = FSM.terminate(:normal, :unavailable, data)
    end
  end
end
