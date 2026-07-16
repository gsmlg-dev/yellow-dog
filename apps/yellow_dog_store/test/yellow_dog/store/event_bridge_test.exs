defmodule YellowDog.Store.EventBridgeTest do
  use ExUnit.Case, async: false

  alias YellowDog.Store.{EventBridge, Key}
  alias YellowDog.Store.Backend.Ets

  setup do
    YellowDog.StoreHelper.setup_store()
    pid = start_supervised!({EventBridge, []})
    %{bridge: pid}
  end

  defp make_event(opts \\ []) do
    %{
      type: Keyword.get(opts, :type, :put),
      key: Keyword.get(opts, :key, "dhcp:lease:v4:aa:bb:cc:dd:ee:ff"),
      value: Keyword.get(opts, :value, %{state: :bound}),
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:microsecond)),
      node: Keyword.get(opts, :node, node())
    }
  end

  describe "subscribe/2 with callback function" do
    test "callback receives dispatched events" do
      test_pid = self()

      {:ok, _ref} =
        EventBridge.subscribe("dhcp:lease:*", fn event ->
          send(test_pid, {:callback_event, event})
        end)

      event = make_event()
      GenServer.cast(EventBridge, {:dispatch, event})

      assert_receive {:callback_event, ^event}, 1000
    end

    test "callback is not called for non-matching events" do
      test_pid = self()

      {:ok, _ref} =
        EventBridge.subscribe("dhcp:lease:*", fn event ->
          send(test_pid, {:callback_event, event})
        end)

      event = make_event(key: "device:aa:bb:cc:dd:ee:ff")
      GenServer.cast(EventBridge, {:dispatch, event})

      refute_receive {:callback_event, _}, 200
    end
  end

  describe "subscribe/1 pid mode" do
    test "subscriber receives {:store_event, event} messages" do
      {:ok, _ref} = EventBridge.subscribe("dhcp:lease:*")

      event = make_event()
      GenServer.cast(EventBridge, {:dispatch, event})

      assert_receive {:store_event, ^event}, 1000
    end

    test "subscriber does not receive non-matching events" do
      {:ok, _ref} = EventBridge.subscribe("dhcp:lease:*")

      event = make_event(key: "device:aa:bb:cc:dd:ee:ff")
      GenServer.cast(EventBridge, {:dispatch, event})

      refute_receive {:store_event, _}, 200
    end
  end

  describe "pattern matching" do
    test "wildcard pattern matches keys with matching prefix" do
      {:ok, _ref} = EventBridge.subscribe("dhcp:lease:*")

      event_v4 = make_event(key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff")
      event_v6 = make_event(key: "dhcp:lease:v6:00:01:aa:bb")

      GenServer.cast(EventBridge, {:dispatch, event_v4})
      GenServer.cast(EventBridge, {:dispatch, event_v6})

      assert_receive {:store_event, ^event_v4}, 1000
      assert_receive {:store_event, ^event_v6}, 1000
    end

    test "wildcard pattern does not match unrelated keys" do
      {:ok, _ref} = EventBridge.subscribe("dhcp:lease:*")

      event = make_event(key: "device:aa:bb:cc:dd:ee:ff")
      GenServer.cast(EventBridge, {:dispatch, event})

      refute_receive {:store_event, _}, 200
    end

    test "exact pattern matches only exact key" do
      {:ok, _ref} = EventBridge.subscribe("dhcp:lease:v4:aa:bb:cc:dd:ee:ff")

      exact_event = make_event(key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff")
      other_event = make_event(key: "dhcp:lease:v4:11:22:33:44:55:66")

      GenServer.cast(EventBridge, {:dispatch, exact_event})
      GenServer.cast(EventBridge, {:dispatch, other_event})

      assert_receive {:store_event, ^exact_event}, 1000
      refute_receive {:store_event, ^other_event}, 200
    end

    test "rpz:* matches rpz keys but not dhcp keys" do
      {:ok, _ref} = EventBridge.subscribe("rpz:*")

      rpz_event = make_event(key: "rpz:blocklist:bad.example.com")
      dhcp_event = make_event(key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff")

      GenServer.cast(EventBridge, {:dispatch, rpz_event})
      GenServer.cast(EventBridge, {:dispatch, dhcp_event})

      assert_receive {:store_event, ^rpz_event}, 1000
      refute_receive {:store_event, ^dhcp_event}, 200
    end
  end

  describe "unsubscribe/1" do
    test "stops receiving events after unsubscribe" do
      {:ok, ref} = EventBridge.subscribe("dhcp:lease:*")

      # Verify subscription works
      event1 = make_event(key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff")
      GenServer.cast(EventBridge, {:dispatch, event1})
      assert_receive {:store_event, ^event1}, 1000

      # Unsubscribe
      :ok = EventBridge.unsubscribe(ref)

      # Allow the cast to be processed
      Process.sleep(50)

      # Verify no more events
      event2 = make_event(key: "dhcp:lease:v4:11:22:33:44:55:66")
      GenServer.cast(EventBridge, {:dispatch, event2})
      refute_receive {:store_event, _}, 200
    end
  end

  describe "multiple subscribers" do
    test "all matching subscribers receive the same event" do
      test_pid = self()

      {:ok, _ref1} = EventBridge.subscribe("dhcp:lease:*")

      {:ok, _ref2} =
        EventBridge.subscribe("dhcp:lease:*", fn event ->
          send(test_pid, {:fn_subscriber, event})
        end)

      event = make_event()
      GenServer.cast(EventBridge, {:dispatch, event})

      assert_receive {:store_event, ^event}, 1000
      assert_receive {:fn_subscriber, ^event}, 1000
    end

    test "only matching subscribers receive events" do
      test_pid = self()
      {:ok, _ref1} = EventBridge.subscribe("dhcp:lease:*")

      {:ok, _ref2} =
        EventBridge.subscribe("device:*", fn event ->
          send(test_pid, {:device_subscriber, event})
        end)

      lease_event = make_event(key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff")
      GenServer.cast(EventBridge, {:dispatch, lease_event})

      assert_receive {:store_event, ^lease_event}, 1000
      refute_receive {:device_subscriber, _}, 200
    end
  end

  describe "notify/3" do
    test "dispatches event to subscribers" do
      {:ok, _ref} = EventBridge.subscribe("dhcp:lease:*")

      EventBridge.notify(:put, "dhcp:lease:v4:aa:bb:cc:dd:ee:ff", %{state: :bound})

      assert_receive {:store_event, event}, 1000
      assert event.type == :put
      assert event.key == "dhcp:lease:v4:aa:bb:cc:dd:ee:ff"
      assert event.value == %{state: :bound}
      assert is_integer(event.timestamp)
      assert event.node == node()
    end

    test "notify with :delete type" do
      {:ok, _ref} = EventBridge.subscribe("dhcp:lease:*")

      EventBridge.notify(:delete, "dhcp:lease:v4:aa:bb:cc:dd:ee:ff", nil)

      assert_receive {:store_event, event}, 1000
      assert event.type == :delete
      assert event.value == nil
    end
  end

  describe "notify_durable/6" do
    test "replays a persisted pending event automatically after EventBridge restart", %{
      bridge: bridge
    } do
      operation_id = "restart-operation"
      cursor = 7
      event_key = Key.zone_replacement_event(operation_id, cursor)
      subject_key = "dns:view:default:zone:restart.example:rr:www:a"

      {:ok, _ref} = EventBridge.subscribe(subject_key)
      :ok = :sys.suspend(bridge)

      assert :ok =
               EventBridge.notify_durable(
                 Ets,
                 operation_id,
                 cursor,
                 :put,
                 subject_key,
                 %{address: {192, 0, 2, 1}}
               )

      assert {:ok, _persisted} = Ets.get(event_key, consistency: :strong)
      Process.exit(bridge, :kill)
      _restarted_bridge = wait_for_restarted_bridge(bridge)
      {:ok, _ref} = EventBridge.subscribe(subject_key)

      assert_receive {:store_event,
                      %{
                        operation_id: ^operation_id,
                        cursor: ^cursor,
                        key: ^subject_key
                      } = delivered},
                     2_000

      assert_event_dispatched(event_key, delivered)
    end
  end

  describe "handler error resilience" do
    test "failing callback does not crash the EventBridge" do
      {:ok, _ref} =
        EventBridge.subscribe("dhcp:lease:*", fn _event ->
          raise "boom"
        end)

      event = make_event()
      GenServer.cast(EventBridge, {:dispatch, event})

      # Give the Task time to crash and recover
      Process.sleep(100)

      # EventBridge should still be alive
      assert Process.alive?(Process.whereis(EventBridge))
    end
  end

  describe "handle_info catch-all" do
    test "unknown messages do not crash the process" do
      send(Process.whereis(EventBridge), :unexpected_message)
      Process.sleep(50)
      assert Process.alive?(Process.whereis(EventBridge))
    end
  end

  defp wait_for_restarted_bridge(previous, attempts \\ 100)

  defp wait_for_restarted_bridge(_previous, 0), do: flunk("EventBridge did not restart")

  defp wait_for_restarted_bridge(previous, attempts) do
    case Process.whereis(EventBridge) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _pid ->
        Process.sleep(10)
        wait_for_restarted_bridge(previous, attempts - 1)
    end
  end

  defp assert_event_dispatched(event_key, delivered, attempts \\ 100)

  defp assert_event_dispatched(_event_key, _delivered, 0),
    do: flunk("durable event was delivered without a durable acknowledgement")

  defp assert_event_dispatched(event_key, delivered, attempts) do
    case Ets.get(event_key, consistency: :strong) do
      {:ok, %{dispatch_state: :dispatched, event: ^delivered}} ->
        :ok

      _pending ->
        Process.sleep(10)
        assert_event_dispatched(event_key, delivered, attempts - 1)
    end
  end
end
