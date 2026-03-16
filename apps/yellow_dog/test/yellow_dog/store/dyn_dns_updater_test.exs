defmodule YellowDog.Store.DynDnsUpdaterTest do
  use ExUnit.Case, async: false

  alias YellowDog.Store.{DynDnsUpdater, EventBridge}

  # DynDnsUpdater subscribes to EventBridge in init/1, and its event handlers
  # call DynDns which requires Concord. We test the event routing logic by
  # inspecting how events flow through EventBridge to the updater process.
  #
  # The actual DynDns.put/DynDns.delete calls will fail without Concord,
  # so we focus on:
  # 1. GenServer starts and subscribes correctly
  # 2. Event messages are received by the updater (pid mode subscription)
  # 3. Classify/FQDN helper logic (tested indirectly)

  setup do
    # EventBridge must be running for DynDnsUpdater to subscribe
    bridge_pid = start_supervised!({EventBridge, []}, id: :test_event_bridge)

    %{bridge: bridge_pid}
  end

  describe "start_link/1" do
    test "starts the DynDnsUpdater process" do
      pid = start_supervised!({DynDnsUpdater, domain: "test.local"})
      assert Process.alive?(pid)
    end

    test "starts with default domain" do
      pid = start_supervised!({DynDnsUpdater, []})
      assert Process.alive?(pid)
    end
  end

  describe "event subscription" do
    test "updater receives lease events via EventBridge" do
      _pid = start_supervised!({DynDnsUpdater, domain: "test.local"})

      # The updater subscribes to "dhcp:lease:*" in pid mode.
      # Dispatch a lease event through EventBridge and verify the updater
      # handles it without crashing (the DynDns calls will fail silently).
      event = %{
        type: :put,
        key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff",
        value: %{
          state: :bound,
          hostname: "testhost",
          ip: {192, 168, 1, 10},
          lease_duration: 3600
        },
        timestamp: System.system_time(:microsecond),
        node: node()
      }

      GenServer.cast(EventBridge, {:dispatch, event})

      # Give the updater time to process the event
      Process.sleep(200)

      # The updater should still be alive (DynDns errors are logged, not raised)
      assert Process.alive?(Process.whereis(DynDnsUpdater))
    end
  end

  describe "handle_info resilience" do
    test "unknown messages do not crash the updater" do
      pid = start_supervised!({DynDnsUpdater, domain: "test.local"})
      send(pid, :unexpected_message)
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "lease event with no hostname is ignored" do
      _pid = start_supervised!({DynDnsUpdater, domain: "test.local"})

      event = %{
        type: :put,
        key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff",
        value: %{state: :bound, hostname: nil, ip: {192, 168, 1, 10}},
        timestamp: System.system_time(:microsecond),
        node: node()
      }

      GenServer.cast(EventBridge, {:dispatch, event})
      Process.sleep(100)
      assert Process.alive?(Process.whereis(DynDnsUpdater))
    end

    test "lease event with empty hostname is ignored" do
      _pid = start_supervised!({DynDnsUpdater, domain: "test.local"})

      event = %{
        type: :put,
        key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff",
        value: %{state: :bound, hostname: "", ip: {192, 168, 1, 10}},
        timestamp: System.system_time(:microsecond),
        node: node()
      }

      GenServer.cast(EventBridge, {:dispatch, event})
      Process.sleep(100)
      assert Process.alive?(Process.whereis(DynDnsUpdater))
    end

    @tag :store_integration
    @tag :skip
    test "delete event with lease value is handled" do
      # Requires running Concord - DynDns.delete raises CaseClauseError
      # when Concord is not available
      _pid = start_supervised!({DynDnsUpdater, domain: "test.local"})

      event = %{
        type: :delete,
        key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff",
        value: %{hostname: "deadhost", state: :released},
        timestamp: System.system_time(:microsecond),
        node: node()
      }

      GenServer.cast(EventBridge, {:dispatch, event})
      Process.sleep(200)
      assert Process.alive?(Process.whereis(DynDnsUpdater))
    end

    test "delete event with nil value is handled" do
      _pid = start_supervised!({DynDnsUpdater, domain: "test.local"})

      event = %{
        type: :delete,
        key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff",
        value: nil,
        timestamp: System.system_time(:microsecond),
        node: node()
      }

      GenServer.cast(EventBridge, {:dispatch, event})
      Process.sleep(100)
      assert Process.alive?(Process.whereis(DynDnsUpdater))
    end
  end

  describe "lease state routing" do
    test "renewing lease event does not crash updater" do
      _pid = start_supervised!({DynDnsUpdater, domain: "test.local"})

      event = %{
        type: :put,
        key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff",
        value: %{
          state: :renewing,
          hostname: "renewhost",
          ip: {192, 168, 1, 20},
          lease_duration: 7200
        },
        timestamp: System.system_time(:microsecond),
        node: node()
      }

      GenServer.cast(EventBridge, {:dispatch, event})
      Process.sleep(200)
      assert Process.alive?(Process.whereis(DynDnsUpdater))
    end

    @tag :store_integration
    @tag :skip
    test "released lease event does not crash updater" do
      # Requires running Concord - DynDns.delete raises CaseClauseError
      # when Concord is not available because it calls Concord.get internally
      _pid = start_supervised!({DynDnsUpdater, domain: "test.local"})

      event = %{
        type: :put,
        key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff",
        value: %{state: :released, hostname: "releasedhost"},
        timestamp: System.system_time(:microsecond),
        node: node()
      }

      GenServer.cast(EventBridge, {:dispatch, event})
      Process.sleep(200)
      assert Process.alive?(Process.whereis(DynDnsUpdater))
    end

    test "offered lease event (no hostname action) does not crash updater" do
      _pid = start_supervised!({DynDnsUpdater, domain: "test.local"})

      event = %{
        type: :put,
        key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff",
        value: %{state: :offered, ip: {192, 168, 1, 30}},
        timestamp: System.system_time(:microsecond),
        node: node()
      }

      GenServer.cast(EventBridge, {:dispatch, event})
      Process.sleep(100)
      assert Process.alive?(Process.whereis(DynDnsUpdater))
    end
  end

  describe "end-to-end DNS record creation" do
    @tag :store_integration
    @tag :skip
    test "bound lease creates forward and reverse records" do
      # Requires running Concord cluster
      _pid = start_supervised!({DynDnsUpdater, domain: "example.local"})

      event = %{
        type: :put,
        key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff",
        value: %{
          state: :bound,
          hostname: "mypc",
          ip: {192, 168, 1, 100},
          lease_duration: 3600
        },
        timestamp: System.system_time(:microsecond),
        node: node()
      }

      GenServer.cast(EventBridge, {:dispatch, event})
      Process.sleep(500)

      # Verify forward record
      assert {:ok, record} = YellowDog.Store.DynDns.get("mypc.example.local.")
      assert record.type == :a
      assert record.rdata == {192, 168, 1, 100}

      # Verify reverse record
      assert {:ok, ptr} = YellowDog.Store.DynDns.get_ptr("100.1.168.192.in-addr.arpa")
      assert ptr.rdata == "mypc.example.local."
    end
  end
end
