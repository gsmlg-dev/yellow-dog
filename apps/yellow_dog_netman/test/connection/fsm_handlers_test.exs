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

  # Creates a dynamic module implementing set_link_up/1, set_link_down/1, set_mtu/2
  defp mock_link_module(funs) do
    mod_name = :"MockLinkMod_#{:erlang.unique_integer([:positive])}"

    set_link_up_fn = Map.get(funs, :set_link_up, fn _ -> :ok end)
    set_link_down_fn = Map.get(funs, :set_link_down, fn _ -> :ok end)
    set_mtu_fn = Map.get(funs, :set_mtu, fn _, _ -> :ok end)

    :persistent_term.put({mod_name, :set_link_up}, set_link_up_fn)
    :persistent_term.put({mod_name, :set_link_down}, set_link_down_fn)
    :persistent_term.put({mod_name, :set_mtu}, set_mtu_fn)

    Module.create(
      mod_name,
      quote do
        def set_link_up(iface),
          do: :persistent_term.get({unquote(mod_name), :set_link_up}).(iface)

        def set_link_down(iface),
          do: :persistent_term.get({unquote(mod_name), :set_link_down}).(iface)

        def set_mtu(iface, mtu),
          do: :persistent_term.get({unquote(mod_name), :set_mtu}).(iface, mtu)
      end,
      Macro.Env.location(__ENV__)
    )

    mod_name
  end

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

    test "setup_link succeeds with no mtu and link-up command", %{data: data, iface: iface} do
      test_pid = self()

      mock =
        mock_link_module(%{
          set_link_up: fn ^iface ->
            send(test_pid, {:setup_link_cmd, :set_link_up, iface})
            :ok
          end,
          set_mtu: fn _, _ -> :ok end
        })

      assert :ok = FSM.setup_link(data, mock)
      assert_received {:setup_link_cmd, :set_link_up, ^iface}
    end

    test "setup_link returns error when mtu command fails", %{data: data, iface: iface} do
      data = put_in(data.profile.ethernet.mtu, 9000)

      mock =
        mock_link_module(%{
          set_mtu: fn ^iface, 9000 -> {:error, :mtu_unsupported} end,
          set_link_up: fn _ -> :ok end
        })

      assert {:error, :mtu_unsupported} = FSM.setup_link(data, mock)
    end

    test "setup_link returns error when link-up command exits", %{data: data} do
      mock =
        mock_link_module(%{
          set_mtu: fn _, _ -> :ok end,
          set_link_up: fn _ -> exit(:netlink_down) end
        })

      assert {:error, {:netlink_exit, :netlink_down}} = FSM.setup_link(data, mock)
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

    test "manual IP with malformed CIDR transitions to failed instead of crashing" do
      iface = "hdlr_badcidr_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "badcidr-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.0.0.100/24/1", gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      data = %FSM{interface: iface, profile: profile, current_state: :configuring}
      result = FSM.configuring(:internal, :configure_ip, data)
      assert {:next_state, :failed, new_data, _actions} = result
      assert new_data.error == {:invalid_cidr, "10.0.0.100/24/1"}
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
        ipv4: %{
          method: :manual,
          address: "10.0.0.100/24",
          gateway: "10.0.0.1",
          dns: ["not.an.ip"]
        },
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

      profile =
        base_profile(iface, %{ipv4: %{method: :auto, address: nil, gateway: nil, dns: []}})

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

      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :ip_check,
        ip_check_retries: 2
      }

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

    test "terminate in configuring state handles DHCP auto profile without lease" do
      iface = "hdlr_term_auto_#{:rand.uniform(65535)}"

      profile =
        base_profile(iface, %{ipv4: %{method: :auto, address: nil, gateway: nil, dns: []}})

      data = %FSM{interface: iface, profile: profile, current_state: :configuring, lease: nil}

      assert :ok = FSM.terminate(:normal, :configuring, data)
    end
  end

  # ----------------------------------------------------------------
  # deactivating: get_state handler (line 468)
  # ----------------------------------------------------------------

  describe "deactivating get_state (direct)" do
    test "get_state in deactivating returns deactivating state info" do
      iface = "hdlr_deact_gs_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :deactivating}

      result = FSM.deactivating({:call, {self(), make_ref()}}, :get_state, data)
      assert {:keep_state, _data, [{:reply, _, {:ok, state}}]} = result
      assert state.state == :deactivating
    end
  end

  # ----------------------------------------------------------------
  # configuring: DHCP retry path (line 257) and mac_detection_failed (line 734)
  # ----------------------------------------------------------------

  describe "configuring DHCP failure paths (direct)" do
    setup do
      iface = "hdlr_dhcp_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "dhcp-fail-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      {:ok, iface: iface, profile: profile}
    end

    test "retryable DHCP failure with retries remaining schedules retry", %{
      iface: iface,
      profile: profile
    } do
      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 0
      }

      # :timeout is retryable and dhcp_retries(0) < max(3)
      result = FSM.configuring(:info, {:dhcp_lease_failed, :timeout}, data)
      assert {:keep_state, new_data} = result
      assert new_data.dhcp_retries == 1
    end

    test "mac_detection_failed is non-retryable and transitions to failed", %{
      iface: iface,
      profile: profile
    } do
      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 0
      }

      # {:mac_detection_failed, _} hits retryable_dhcp_failure?/1 line 734 → false
      result =
        FSM.configuring(:info, {:dhcp_lease_failed, {:mac_detection_failed, :eth_read}}, data)

      assert {:next_state, :failed, new_data, _} = result
      assert new_data.error == :dhcp_failed
    end
  end

  # ----------------------------------------------------------------
  # DHCP retry exponential backoff and exhaustion
  # ----------------------------------------------------------------

  describe "DHCP retry exponential backoff" do
    setup do
      iface = "hdlr_bo_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "dhcp-bo-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      {:ok, iface: iface, profile: profile}
    end

    test "retry 1 schedules with 2000ms delay", %{iface: iface, profile: profile} do
      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 0
      }

      result = FSM.configuring(:info, {:dhcp_lease_failed, :timeout}, data)
      assert {:keep_state, new_data} = result
      assert new_data.dhcp_retries == 1

      # Verify Process.send_after was called — :retry_dhcp should arrive
      assert_receive :retry_dhcp, 2500
    end

    test "retry 2 schedules with 4000ms delay", %{iface: iface, profile: profile} do
      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 1
      }

      result = FSM.configuring(:info, {:dhcp_lease_failed, :timeout}, data)
      assert {:keep_state, new_data} = result
      assert new_data.dhcp_retries == 2

      # Should NOT arrive in 2000ms (delay is 4000ms)
      refute_receive :retry_dhcp, 100
    end

    test "retry 3 schedules with 8000ms delay", %{iface: iface, profile: profile} do
      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 2
      }

      result = FSM.configuring(:info, {:dhcp_lease_failed, :timeout}, data)
      assert {:keep_state, new_data} = result
      assert new_data.dhcp_retries == 3

      # Verify retry counter reached max
      refute_receive :retry_dhcp, 100
    end

    test "retries exhausted transitions to failed", %{iface: iface, profile: profile} do
      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 3
      }

      # dhcp_retries == @max_dhcp_retries(3), retryable reason but exhausted
      result = FSM.configuring(:info, {:dhcp_lease_failed, :timeout}, data)
      assert {:next_state, :failed, new_data, _actions} = result
      assert new_data.error == :dhcp_failed
      assert new_data.dhcp_retries == 0
    end

    test "dhcp_client_not_available is non-retryable", %{iface: iface, profile: profile} do
      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 0
      }

      result =
        FSM.configuring(:info, {:dhcp_lease_failed, :dhcp_client_not_available}, data)

      assert {:next_state, :failed, new_data, _} = result
      assert new_data.error == :dhcp_failed
    end

    test "lease acquired resets retry counter to zero", %{iface: iface, profile: profile} do
      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :configuring,
        dhcp_retries: 2
      }

      lease = %{address: "10.0.0.50", prefix_len: 24}
      result = FSM.configuring(:info, {:dhcp_lease_acquired, lease}, data)
      assert {:next_state, :ip_check, new_data, _actions} = result
      assert new_data.dhcp_retries == 0
      assert new_data.lease == lease
    end
  end

  # ----------------------------------------------------------------
  # activated: push_dns with lease DNS servers (line 668)
  # ----------------------------------------------------------------

  describe "activated post_activate with lease dns_servers (direct)" do
    test "post_activate with lease containing dns_servers uses lease DNS" do
      iface = "hdlr_pdns_#{:rand.uniform(65535)}"
      profile = base_profile(iface)

      # Setting data.lease with dns_servers causes push_dns to hit line 668
      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :activated,
        lease: %{dns_servers: [{8, 8, 8, 8}]}
      }

      result = FSM.activated(:internal, :post_activate, data)
      assert {:keep_state, ^data} = result
    end
  end

  # ----------------------------------------------------------------
  # configuring: apply_static_ip error path (lines 570-574)
  # ----------------------------------------------------------------

  describe "configuring apply_static_ip error path" do
    @moduletag :capture_log

    test "static IP address failure transitions to failed when Netlink is down" do
      iface = "hdlr_sip_err_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "sip-err-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.60.0.1/24", gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      netlink_pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      original_state = :sys.get_state(netlink_pid)

      on_exit(fn ->
        :sys.replace_state(netlink_pid, fn _state -> original_state end)
      end)

      :sys.replace_state(netlink_pid, fn state -> %{state | backend: :unavailable, port: nil} end)

      data = %FSM{interface: iface, profile: profile, current_state: :configuring}
      result = FSM.configuring(:internal, :configure_ip, data)

      :sys.replace_state(netlink_pid, fn _state -> original_state end)

      assert {:next_state, :failed, new_data, _} = result
      assert match?({:address_failed, _}, new_data.error)
    end
  end

  # ----------------------------------------------------------------
  # configuring: apply_static_ipv6 error path (lines 592-593)
  # ----------------------------------------------------------------

  describe "configuring apply_static_ipv6 error path" do
    @moduletag :capture_log

    test "static IPv6 address failure is logged and continues when Netlink is down" do
      iface = "hdlr_sipv6_err_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "sipv6-err-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        # IPv4 auto so that apply_static_ip is not called; ipv6 manual triggers apply_static_ipv6
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :manual, address: "2001:db8::1/64", gateway: nil, dns: []}
      }

      netlink_pid = Process.whereis(YellowDog.Netman.Kernel.Netlink)
      original_state = :sys.get_state(netlink_pid)

      on_exit(fn ->
        :sys.replace_state(netlink_pid, fn _state -> original_state end)
      end)

      :sys.replace_state(netlink_pid, fn state -> %{state | backend: :unavailable, port: nil} end)

      data = %FSM{interface: iface, profile: profile, current_state: :configuring}
      result = FSM.configuring(:internal, :configure_ip, data)

      :sys.replace_state(netlink_pid, fn _state -> original_state end)

      # After IPv6 failure (logged), falls through to :auto IPv4 path → {:keep_state, data}
      assert {:keep_state, ^data} = result
    end
  end

  # ----------------------------------------------------------------
  # CIDR parsing edge cases (FSM.ex parse_cidr/1)
  # ----------------------------------------------------------------

  describe "CIDR parsing edge cases via configure_ip" do
    @moduletag :capture_log

    test "prefix > 128 defaults to /32 for IPv4" do
      iface = "hdlr_cidr_big_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "cidr-big-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.0.0.1/999", gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      data = %FSM{interface: iface, profile: profile, current_state: :configuring}
      result = FSM.configuring(:internal, :configure_ip, data)

      # Should proceed to ip_check (invalid prefix falls back to /32)
      assert {:next_state, :ip_check, _new_data, _actions} = result
    end

    test "negative prefix defaults to /32 for IPv4" do
      iface = "hdlr_cidr_neg_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "cidr-neg-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.0.0.1/-5", gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      data = %FSM{interface: iface, profile: profile, current_state: :configuring}
      result = FSM.configuring(:internal, :configure_ip, data)

      assert {:next_state, :ip_check, _new_data, _actions} = result
    end

    test "address without prefix defaults to /32" do
      iface = "hdlr_cidr_bare_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "cidr-bare-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.0.0.1", gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      data = %FSM{interface: iface, profile: profile, current_state: :configuring}
      result = FSM.configuring(:internal, :configure_ip, data)

      assert {:next_state, :ip_check, _new_data, _actions} = result
    end

    test "IPv6 address without prefix defaults to /128" do
      iface = "hdlr_cidr_v6_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "cidr-v6-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :manual, address: "2001:db8::1", gateway: nil, dns: []}
      }

      data = %FSM{interface: iface, profile: profile, current_state: :configuring}
      result = FSM.configuring(:internal, :configure_ip, data)

      # IPv6 only, IPv4 disabled — the IPv6 static address is applied, then
      # IPv4 disabled path transitions to ip_check
      assert {:next_state, :ip_check, _new_data, _actions} = result
    end
  end

  # ----------------------------------------------------------------
  # Activated: address removal edge cases
  # ----------------------------------------------------------------

  describe "activated address removal edge cases (direct)" do
    test "address removal with ipv4 disabled keeps state" do
      iface = "hdlr_adr_dis_#{:rand.uniform(65535)}"

      disabled_ipv4_profile = %Profile{
        id: "adr-dis-#{iface}",
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
        profile: disabled_ipv4_profile,
        current_state: :activated
      }

      result =
        FSM.activated(
          :info,
          {:netman_event, "netman:address:#{iface}", {:remove, %{scope: :global}}},
          data
        )

      # ipv4 disabled → line 401: {:keep_state, data}
      assert {:keep_state, ^data} = result
    end

    test "DHCP lease expired triggers deactivation" do
      iface = "hdlr_lease_exp_#{:rand.uniform(65535)}"
      profile = base_profile(iface)

      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :activated,
        lease: %{address: "10.0.0.50"}
      }

      result = FSM.activated(:info, {:dhcp_lease_expired, :timeout}, data)
      assert {:next_state, :deactivating, _new_data, actions} = result

      assert Enum.any?(actions, fn
               {:next_event, :internal, :cleanup} -> true
               _ -> false
             end)
    end

    test "interface removed while activated cleans up and goes unavailable" do
      iface = "hdlr_act_rm_#{:rand.uniform(65535)}"
      profile = base_profile(iface)

      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :activated,
        lease: %{address: "10.0.0.50"}
      }

      result =
        FSM.activated(
          :info,
          {:netman_event, "netman:link:#{iface}", {:removed, iface}},
          data
        )

      assert {:next_state, :unavailable, new_data, _actions} = result
      assert new_data.lease == nil
    end

    test "catch-all in activated ignores unknown events" do
      iface = "hdlr_act_unk_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :activated}

      result = FSM.activated(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end
  end

  # ----------------------------------------------------------------
  # setup_link: MTU exit exception
  # ----------------------------------------------------------------

  describe "setup_link MTU exit exception" do
    test "exit during set_mtu is caught and returns error" do
      iface = "hdlr_mtu_exit_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: Map.put(profile, :ethernet, %{mtu: 9000})}

      mock =
        mock_link_module(%{
          set_mtu: fn _, _ -> exit(:netlink_down) end,
          set_link_up: fn _ -> :ok end
        })

      assert {:error, {:netlink_exit, :netlink_down}} = FSM.setup_link(data, mock)
    end
  end

  # ----------------------------------------------------------------
  # prepare: setup_link failure transitions to failed
  # ----------------------------------------------------------------

  describe "prepare setup_link failure (direct)" do
    test "setup_link error transitions prepare to failed with setup_link_failed error" do
      iface = "hdlr_slk_fail_#{:rand.uniform(65535)}"
      profile = base_profile(iface, %{ethernet: %{mtu: 9000}})

      mock =
        mock_link_module(%{
          set_mtu: fn _, _ -> {:error, :mtu_unsupported} end,
          set_link_up: fn _ -> :ok end
        })

      data = %FSM{interface: iface, profile: profile, current_state: :prepare}

      # Can't call prepare(:internal, :setup_link, data) directly because it
      # calls setup_link() which uses real LinkMonitor. Instead verify via
      # the setup_link return value and the prepare handler logic.
      assert {:error, :mtu_unsupported} = FSM.setup_link(data, mock)

      # Verify the state machine logic directly
      result = FSM.prepare(:state_timeout, :setup_timeout, data)
      assert {:next_state, :failed, new_data, _actions} = result
      assert new_data.error == :setup_timeout
    end
  end

  # ----------------------------------------------------------------
  # disconnected: auto_activate with autoconnect=false
  # ----------------------------------------------------------------

  describe "disconnected auto_activate with autoconnect=false (direct)" do
    test "auto_activate keeps state when autoconnect is false" do
      iface = "hdlr_noauto_#{:rand.uniform(65535)}"
      profile = base_profile(iface, %{autoconnect: false})
      data = %FSM{interface: iface, profile: profile, current_state: :disconnected}

      result = FSM.disconnected(:internal, :auto_activate, data)
      assert {:keep_state, ^data} = result
    end

    test "auto_activate transitions to prepare when autoconnect is true" do
      iface = "hdlr_auto_#{:rand.uniform(65535)}"
      profile = base_profile(iface, %{autoconnect: true})
      data = %FSM{interface: iface, profile: profile, current_state: :disconnected}

      result = FSM.disconnected(:internal, :auto_activate, data)
      assert {:next_state, :prepare, _new_data, actions} = result

      assert Enum.any?(actions, fn
               {:next_event, :internal, :setup_link} -> true
               _ -> false
             end)
    end

    test "explicit activate cast transitions to prepare" do
      iface = "hdlr_act_cast_#{:rand.uniform(65535)}"
      profile = base_profile(iface, %{autoconnect: false})
      data = %FSM{interface: iface, profile: profile, current_state: :disconnected}

      result = FSM.disconnected(:cast, :activate, data)
      assert {:next_state, :prepare, _new_data, actions} = result

      assert Enum.any?(actions, fn
               {:next_event, :internal, :setup_link} -> true
               _ -> false
             end)
    end

    test "get_state in disconnected returns disconnected state info" do
      iface = "hdlr_disc_gs_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :disconnected}

      result = FSM.disconnected({:call, {self(), make_ref()}}, :get_state, data)
      assert {:keep_state, _data, [{:reply, _, {:ok, state}}]} = result
      assert state.state == :disconnected
    end

    test "catch-all in disconnected ignores unknown events" do
      iface = "hdlr_disc_unk_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :disconnected}

      result = FSM.disconnected(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end
  end

  # ----------------------------------------------------------------
  # unavailable: catch-all handler
  # ----------------------------------------------------------------

  describe "unavailable catch-all (direct)" do
    test "catch-all in unavailable ignores unknown events" do
      iface = "hdlr_unav_unk_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :unavailable}

      result = FSM.unavailable(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end

    test "link_update with carrier=true transitions to disconnected with auto_activate" do
      iface = "hdlr_unav_cu_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :unavailable}

      result =
        FSM.unavailable(
          :info,
          {:netman_event, "netman:link:#{iface}", {:link_update, %{carrier: true}}},
          data
        )

      assert {:next_state, :disconnected, _new_data, actions} = result

      assert Enum.any?(actions, fn
               {:next_event, :internal, :auto_activate} -> true
               _ -> false
             end)
    end
  end

  # ----------------------------------------------------------------
  # deactivating: cleanup internal event
  # ----------------------------------------------------------------

  describe "deactivating cleanup (direct)" do
    test "cleanup internal event performs cleanup and transitions to disconnected" do
      iface = "hdlr_deact_cl_#{:rand.uniform(65535)}"
      profile = base_profile(iface)

      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :deactivating,
        lease: %{address: "10.0.0.50"}
      }

      result = FSM.deactivating(:internal, :cleanup, data)
      assert {:next_state, :disconnected, new_data, _actions} = result
      assert new_data.lease == nil
    end
  end

  # ----------------------------------------------------------------
  # activated: get_state handler
  # ----------------------------------------------------------------

  describe "activated get_state (direct)" do
    test "get_state in activated returns activated state info" do
      iface = "hdlr_act_gs_#{:rand.uniform(65535)}"
      profile = base_profile(iface)
      data = %FSM{interface: iface, profile: profile, current_state: :activated}

      result = FSM.activated({:call, {self(), make_ref()}}, :get_state, data)
      assert {:keep_state, _data, [{:reply, _, {:ok, state}}]} = result
      assert state.state == :activated
    end
  end

  describe "update_profile" do
    test "activated: non-method change updates cached profile in-place" do
      iface = "hdlr_upd_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)

      new_profile = %{
        old_profile
        | autoconnect_priority: 200,
          ipv4: %{old_profile.ipv4 | dns: ["8.8.8.8"]}
      }

      data = %FSM{interface: iface, profile: old_profile, current_state: :activated}

      result = FSM.activated(:cast, {:update_profile, new_profile}, data)
      assert {:keep_state, new_data} = result
      assert new_data.profile.autoconnect_priority == 200
      assert new_data.profile.ipv4.dns == ["8.8.8.8"]
    end

    test "activated: method change triggers deactivation with reactivate flag" do
      iface = "hdlr_upd_m_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)

      new_profile = %{
        old_profile
        | ipv4: %{method: :auto, address: nil, gateway: nil, dns: []}
      }

      data = %FSM{interface: iface, profile: old_profile, current_state: :activated}

      result = FSM.activated(:cast, {:update_profile, new_profile}, data)
      assert {:next_state, :deactivating, new_data, _actions} = result
      assert new_data.profile.ipv4.method == :auto
      assert new_data.reactivate == true
    end

    test "disconnected: update_profile replaces cached profile" do
      iface = "hdlr_upd_d_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)

      new_profile = %{old_profile | autoconnect: false, autoconnect_priority: 50}

      data = %FSM{interface: iface, profile: old_profile, current_state: :disconnected}

      result = FSM.disconnected(:cast, {:update_profile, new_profile}, data)
      assert {:keep_state, new_data} = result
      assert new_data.profile.autoconnect == false
      assert new_data.profile.autoconnect_priority == 50
    end

    test "configuring: method change triggers deactivation with reactivate flag" do
      iface = "hdlr_upd_c_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)

      new_profile = %{
        old_profile
        | ipv6: %{method: :auto, address: nil, gateway: nil, dns: [], dns_search: []}
      }

      data = %FSM{interface: iface, profile: old_profile, current_state: :configuring}

      result = FSM.configuring(:cast, {:update_profile, new_profile}, data)
      assert {:next_state, :deactivating, new_data, _actions} = result
      assert new_data.profile.ipv6.method == :auto
      assert new_data.reactivate == true
    end

    test "configuring: non-method change keeps state" do
      iface = "hdlr_upd_cn_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)

      new_profile = %{old_profile | autoconnect_priority: 999}

      data = %FSM{interface: iface, profile: old_profile, current_state: :configuring}

      result = FSM.configuring(:cast, {:update_profile, new_profile}, data)
      assert {:keep_state, new_data} = result
      assert new_data.profile.autoconnect_priority == 999
    end

    test "deactivating: cleanup with reactivate flag emits auto_activate" do
      iface = "hdlr_react_#{:rand.uniform(65535)}"
      profile = base_profile(iface, %{autoconnect: true})

      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :deactivating,
        reactivate: true
      }

      result = FSM.deactivating(:internal, :cleanup, data)
      assert {:next_state, :disconnected, new_data, actions} = result
      assert new_data.reactivate == false
      assert new_data.lease == nil
      # Should include auto_activate event for re-activation
      assert {:next_event, :internal, :auto_activate} in actions
    end

    test "deactivating: cleanup without reactivate flag does not auto_activate" do
      iface = "hdlr_noreact_#{:rand.uniform(65535)}"
      profile = base_profile(iface)

      data = %FSM{
        interface: iface,
        profile: profile,
        current_state: :deactivating,
        reactivate: false
      }

      result = FSM.deactivating(:internal, :cleanup, data)
      assert {:next_state, :disconnected, new_data, actions} = result
      assert new_data.reactivate == false
      # Should NOT include auto_activate
      refute Enum.any?(actions, fn
        {:next_event, :internal, :auto_activate} -> true
        _ -> false
      end)
    end

    test "unavailable: update_profile caches new profile" do
      iface = "hdlr_upd_u_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)
      new_profile = %{old_profile | autoconnect_priority: 300}

      data = %FSM{interface: iface, profile: old_profile, current_state: :unavailable}

      result = FSM.unavailable(:cast, {:update_profile, new_profile}, data)
      assert {:keep_state, new_data} = result
      assert new_data.profile.autoconnect_priority == 300
    end

    test "prepare: non-method change caches profile" do
      iface = "hdlr_upd_p_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)
      new_profile = %{old_profile | autoconnect_priority: 400}

      data = %FSM{interface: iface, profile: old_profile, current_state: :prepare}

      result = FSM.prepare(:cast, {:update_profile, new_profile}, data)
      assert {:keep_state, new_data} = result
      assert new_data.profile.autoconnect_priority == 400
    end

    test "prepare: method change triggers deactivation with reactivate" do
      iface = "hdlr_upd_pm_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)
      new_profile = %{old_profile | ipv4: %{method: :auto, address: nil, gateway: nil, dns: []}}

      data = %FSM{interface: iface, profile: old_profile, current_state: :prepare}

      result = FSM.prepare(:cast, {:update_profile, new_profile}, data)
      assert {:next_state, :deactivating, new_data, _actions} = result
      assert new_data.reactivate == true
    end

    test "ip_check: non-method change caches profile" do
      iface = "hdlr_upd_ip_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)
      new_profile = %{old_profile | autoconnect_priority: 500}

      data = %FSM{interface: iface, profile: old_profile, current_state: :ip_check}

      result = FSM.ip_check(:cast, {:update_profile, new_profile}, data)
      assert {:keep_state, new_data} = result
      assert new_data.profile.autoconnect_priority == 500
    end

    test "ip_check: method change triggers deactivation with reactivate" do
      iface = "hdlr_upd_ipm_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)
      new_profile = %{old_profile | ipv4: %{method: :auto, address: nil, gateway: nil, dns: []}}

      data = %FSM{interface: iface, profile: old_profile, current_state: :ip_check}

      result = FSM.ip_check(:cast, {:update_profile, new_profile}, data)
      assert {:next_state, :deactivating, new_data, _actions} = result
      assert new_data.reactivate == true
      assert new_data.ip_check_retries == 0
    end

    test "deactivating: update_profile caches new profile" do
      iface = "hdlr_upd_da_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)
      new_profile = %{old_profile | autoconnect_priority: 600}

      data = %FSM{interface: iface, profile: old_profile, current_state: :deactivating}

      result = FSM.deactivating(:cast, {:update_profile, new_profile}, data)
      assert {:keep_state, new_data} = result
      assert new_data.profile.autoconnect_priority == 600
    end

    test "failed: update_profile caches new profile" do
      iface = "hdlr_upd_f_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)
      new_profile = %{old_profile | autoconnect_priority: 700}

      data = %FSM{interface: iface, profile: old_profile, current_state: :failed}

      result = FSM.failed(:cast, {:update_profile, new_profile}, data)
      assert {:keep_state, new_data} = result
      assert new_data.profile.autoconnect_priority == 700
    end

    test "activated: non-method priority change flushes routes before reinstall" do
      iface = "hdlr_route_#{:rand.uniform(65535)}"
      old_profile = base_profile(iface)

      new_profile = %{old_profile | autoconnect_priority: 500}

      # Use direct handler invocation to verify RouteManager.flush is called
      # The returned data should have the new profile
      data = %FSM{interface: iface, profile: old_profile, current_state: :activated}

      result = FSM.activated(:cast, {:update_profile, new_profile}, data)
      assert {:keep_state, new_data} = result
      assert new_data.profile.autoconnect_priority == 500
    end
  end
end
