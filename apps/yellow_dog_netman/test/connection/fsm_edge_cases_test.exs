defmodule YellowDog.Netman.Connection.FSMEdgeCasesTest do
  @moduledoc """
  Tests for FSM edge cases not covered by existing test suites:
  - disconnected auto_activate with autoconnect=false
  - failed state: carrier recovery via direct handler
  - failed state: interface removal transition
  - catch-all handlers in each state
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection.FSM
  alias YellowDog.Netman.Types.Profile

  @moduletag :capture_log

  defp make_data(overrides) do
    profile = %Profile{
      id: "edge-test-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: "edge_eth#{:rand.uniform(100_000)}",
      autoconnect: Map.get(overrides, :autoconnect, false),
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    %FSM{
      interface: profile.interface,
      profile: profile,
      current_state: Map.get(overrides, :state, :disconnected)
    }
  end

  describe "disconnected auto_activate with autoconnect=false" do
    test "auto_activate keeps state when autoconnect is false" do
      data = make_data(%{autoconnect: false})
      result = FSM.disconnected(:internal, :auto_activate, data)
      assert {:keep_state, ^data} = result
    end

    test "auto_activate transitions to prepare when autoconnect is true" do
      data = make_data(%{autoconnect: true})
      result = FSM.disconnected(:internal, :auto_activate, data)
      assert {:next_state, :prepare, _, _} = result
    end
  end

  describe "failed state: carrier recovery" do
    test "carrier true in failed state transitions to disconnected with auto_activate" do
      data = make_data(%{state: :failed})
      data = %{data | error: :dhcp_failed, dhcp_retries: 3}

      event = {:netman_event, "netman:link:#{data.interface}", {:link_update, %{carrier: true}}}
      result = FSM.failed(:info, event, data)

      assert {:next_state, :disconnected, new_data, actions} = result
      assert new_data.error == nil
      assert new_data.dhcp_retries == 0
      assert new_data.ip_check_retries == 0
      assert {:next_event, :internal, :auto_activate} in actions
    end

    test "carrier false in failed state keeps state (catch-all)" do
      data = make_data(%{state: :failed})
      data = %{data | error: :dhcp_failed}

      event = {:netman_event, "netman:link:#{data.interface}", {:link_update, %{carrier: false}}}
      result = FSM.failed(:info, event, data)

      assert {:keep_state, ^data} = result
    end
  end

  describe "failed state: interface removal" do
    test "interface removed in failed state transitions to unavailable" do
      data = make_data(%{state: :failed})
      data = %{data | error: :dhcp_failed}

      event = {:netman_event, "netman:link:#{data.interface}", {:removed, %{}}}
      result = FSM.failed(:info, event, data)

      assert {:next_state, :unavailable, new_data, _} = result
      assert new_data.error == nil
    end
  end

  describe "failed state: deactivate clears error state" do
    test "deactivate from failed clears error and transitions to disconnected" do
      data = make_data(%{state: :failed})
      data = %{data | error: :dhcp_failed, dhcp_retries: 3, ip_check_retries: 5}

      result = FSM.failed(:cast, :deactivate, data)

      assert {:next_state, :disconnected, new_data, _} = result
      assert new_data.error == nil
      assert new_data.lease == nil
      assert new_data.dhcp_retries == 0
      assert new_data.ip_check_retries == 0
    end
  end

  describe "failed state: activate resets and retries" do
    test "activate from failed transitions to disconnected with auto_activate" do
      data = make_data(%{state: :failed})
      data = %{data | error: :dhcp_failed, dhcp_retries: 3}

      result = FSM.failed(:cast, :activate, data)

      assert {:next_state, :disconnected, new_data, actions} = result
      assert new_data.error == nil
      assert new_data.dhcp_retries == 0
      assert {:next_event, :internal, :auto_activate} in actions
    end
  end

  describe "catch-all handlers" do
    test "unavailable catch-all keeps state" do
      data = make_data(%{state: :unavailable})
      result = FSM.unavailable(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end

    test "disconnected catch-all keeps state" do
      data = make_data(%{state: :disconnected})
      result = FSM.disconnected(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end

    test "prepare catch-all keeps state" do
      data = make_data(%{state: :prepare})
      result = FSM.prepare(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end

    test "activated catch-all keeps state" do
      data = make_data(%{state: :activated})
      result = FSM.activated(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end

    test "deactivating catch-all keeps state" do
      data = make_data(%{state: :deactivating})
      result = FSM.deactivating(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end

    test "failed catch-all keeps state" do
      data = make_data(%{state: :failed})
      result = FSM.failed(:info, :unknown_event, data)
      assert {:keep_state, ^data} = result
    end
  end

  describe "disconnected state: interface removal" do
    test "interface removed in disconnected state transitions to unavailable" do
      data = make_data(%{state: :disconnected})

      event = {:netman_event, "netman:link:#{data.interface}", {:removed, %{}}}
      result = FSM.disconnected(:info, event, data)

      assert {:next_state, :unavailable, _, _} = result
    end
  end

  describe "configuring state: IPv4 disabled method" do
    test "disabled IPv4 method skips DHCP and goes to ip_check" do
      data = make_data(%{state: :configuring})

      result = FSM.configuring(:internal, :configure_ip, data)
      assert {:next_state, :ip_check, _, actions} = result
      assert {:next_event, :internal, :check_ip} in actions
    end
  end
end
