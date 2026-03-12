defmodule YellowDog.Netman.EventBusTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.EventBus

  setup do
    # EventBus is started by the application, just subscribe
    :ok
  end

  test "subscribe and publish" do
    EventBus.subscribe("test:topic:1")
    EventBus.publish("test:topic:1", :hello)
    assert_receive {:netman_event, "test:topic:1", :hello}
  end

  test "publish to unsubscribed topic does not deliver" do
    EventBus.subscribe("test:topic:2")
    EventBus.publish("test:other:topic", :hello)
    refute_receive {:netman_event, _, _}, 50
  end

  test "unsubscribe stops delivery" do
    EventBus.subscribe("test:topic:3")
    EventBus.unsubscribe("test:topic:3")
    EventBus.publish("test:topic:3", :hello)
    refute_receive {:netman_event, _, _}, 50
  end

  test "multiple subscribers receive messages" do
    parent = self()

    task1 =
      Task.async(fn ->
        EventBus.subscribe("test:multi:1")
        send(parent, :subscribed)
        assert_receive {:netman_event, "test:multi:1", :msg}, 500
      end)

    # Wait for subscription
    assert_receive :subscribed

    EventBus.subscribe("test:multi:1")
    EventBus.publish("test:multi:1", :msg)

    assert_receive {:netman_event, "test:multi:1", :msg}
    Task.await(task1)
  end

  test "broadcast delivers to all prefix-matching subscribers" do
    EventBus.subscribe("netman:link:eth0")
    EventBus.subscribe("netman:link:eth1")

    EventBus.broadcast("netman:link:", :carrier_change)

    assert_receive {:netman_event, "netman:link:eth0", :carrier_change}
    assert_receive {:netman_event, "netman:link:eth1", :carrier_change}
  end

  test "broadcast does not deliver to non-matching topics" do
    EventBus.subscribe("netman:address:eth0")

    EventBus.broadcast("netman:link:", :carrier_change)

    refute_receive {:netman_event, _, :carrier_change}, 50
  end

  test "broadcast with no subscribers does nothing" do
    assert :ok = EventBus.broadcast("netman:nonexistent:", :ping)
    refute_receive {:netman_event, _, _}, 50
  end

  test "wildcard subscription receives events published to matching topics" do
    EventBus.subscribe("test:wildcard:*")
    EventBus.publish("test:wildcard:foo", :hello)

    assert_receive {:netman_event, "test:wildcard:foo", :hello}
  end

  test "wildcard subscription does not receive events from non-matching topics" do
    EventBus.subscribe("test:wc_other:*")
    EventBus.publish("test:no_match:bar", :hello)

    refute_receive {:netman_event, _, _}, 50
  end

  test "wildcard and exact subscriptions both receive events" do
    EventBus.subscribe("test:both:*")
    EventBus.subscribe("test:both:specific")
    EventBus.publish("test:both:specific", :msg)

    # Should receive from both exact match AND wildcard match
    assert_receive {:netman_event, "test:both:specific", :msg}
    assert_receive {:netman_event, "test:both:specific", :msg}
  end

  test "nested wildcards at different depths both match" do
    EventBus.subscribe("test:nested:*")
    EventBus.subscribe("test:nested:sub:*")
    EventBus.publish("test:nested:sub:deep", :nested_msg)

    # Both wildcards should match since "test:nested:sub:deep" starts with both prefixes
    assert_receive {:netman_event, "test:nested:sub:deep", :nested_msg}
    assert_receive {:netman_event, "test:nested:sub:deep", :nested_msg}
  end

  test "shallow wildcard does not match shorter topic" do
    EventBus.subscribe("test:shallow:longer:*")
    EventBus.publish("test:shallow:x", :msg)

    refute_receive {:netman_event, _, _}, 50
  end

  test "unsubscribe is idempotent" do
    EventBus.subscribe("test:idempotent:1")
    EventBus.unsubscribe("test:idempotent:1")
    # Second unsubscribe should not error
    EventBus.unsubscribe("test:idempotent:1")
    EventBus.publish("test:idempotent:1", :msg)
    refute_receive {:netman_event, _, _}, 50
  end

  test "unsubscribe from never-subscribed topic is safe" do
    EventBus.unsubscribe("test:never:subscribed:#{:rand.uniform(100_000)}")
    # No error, no crash
    assert true
  end

  test "wildcard unsubscribe stops delivery" do
    EventBus.subscribe("test:wc_unsub:*")
    EventBus.publish("test:wc_unsub:foo", :before)
    assert_receive {:netman_event, "test:wc_unsub:foo", :before}

    EventBus.unsubscribe("test:wc_unsub:*")
    EventBus.publish("test:wc_unsub:bar", :after)
    refute_receive {:netman_event, _, _}, 50
  end

  test "wildcard does not match across different namespace prefixes" do
    EventBus.subscribe("test:ns_a:*")
    EventBus.publish("test:ns_ab:event", :msg)
    refute_receive {:netman_event, _, _}, 50
  end

  test "bare wildcard '*' matches all topics as catch-all" do
    EventBus.subscribe("*")
    EventBus.publish("any:topic:at:all", :catch_all)
    assert_receive {:netman_event, "any:topic:at:all", :catch_all}
    EventBus.unsubscribe("*")
  end

  test "publish to topic with no subscribers does not crash" do
    unique = "test:no_sub:#{System.unique_integer([:positive])}"
    assert :ok = EventBus.publish(unique, :orphan)
    refute_receive {:netman_event, _, _}, 50
  end

  test "broadcast also dispatches to wildcard subscribers" do
    EventBus.subscribe("test:bcast_wc:*")
    EventBus.broadcast("test:bcast_wc:", :broadcast_msg)
    assert_receive {:netman_event, "test:bcast_wc:", :broadcast_msg}
  end

  test "broadcast to wildcard subscribers does not match unrelated prefixes" do
    EventBus.subscribe("test:bcast_other:*")
    EventBus.broadcast("test:bcast_wc:", :msg)
    refute_receive {:netman_event, _, _}, 50
  end
end
