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
end
