defmodule YellowDog.Store.ConfigWatcherTest do
  use ExUnit.Case, async: false

  alias YellowDog.Store.{ConfigWatcher, EventBridge}

  setup do
    start_supervised!({EventBridge, []})
    :ok
  end

  test "starts with required options" do
    pid =
      start_supervised!(
        {ConfigWatcher, service: :dns, handler: fn _key, _value -> :ok end, name: :test_cw_start}
      )

    assert Process.alive?(pid)
  end

  test "invokes handler on matching config event" do
    test_pid = self()

    handler = fn key, value ->
      send(test_pid, {:config_changed, key, value})
    end

    start_supervised!({ConfigWatcher, service: :dns, handler: handler, name: :test_cw_handler})

    event = %{
      type: :put,
      key: "config:dns:upstream_servers",
      value: ["8.8.8.8", "1.1.1.1"],
      timestamp: System.system_time(:microsecond),
      node: node()
    }

    GenServer.cast(EventBridge, {:dispatch, event})

    assert_receive {:config_changed, "upstream_servers", ["8.8.8.8", "1.1.1.1"]}, 500
  end

  test "passes nil value for delete events" do
    test_pid = self()

    handler = fn key, value ->
      send(test_pid, {:config_changed, key, value})
    end

    start_supervised!({ConfigWatcher, service: :dns, handler: handler, name: :test_cw_delete})

    event = %{
      type: :delete,
      key: "config:dns:upstream_servers",
      value: nil,
      timestamp: System.system_time(:microsecond),
      node: node()
    }

    GenServer.cast(EventBridge, {:dispatch, event})

    assert_receive {:config_changed, "upstream_servers", nil}, 500
  end

  test "ignores events for other services" do
    test_pid = self()

    handler = fn key, value ->
      send(test_pid, {:config_changed, key, value})
    end

    start_supervised!({ConfigWatcher, service: :dns, handler: handler, name: :test_cw_ignore})

    event = %{
      type: :put,
      key: "config:dhcpv4:pool_size",
      value: 100,
      timestamp: System.system_time(:microsecond),
      node: node()
    }

    GenServer.cast(EventBridge, {:dispatch, event})

    refute_receive {:config_changed, _, _}, 200
  end

  test "survives handler errors" do
    handler = fn _key, _value ->
      raise "boom"
    end

    pid =
      start_supervised!({ConfigWatcher, service: :dns, handler: handler, name: :test_cw_error})

    event = %{
      type: :put,
      key: "config:dns:broken",
      value: true,
      timestamp: System.system_time(:microsecond),
      node: node()
    }

    GenServer.cast(EventBridge, {:dispatch, event})
    Process.sleep(100)

    assert Process.alive?(pid)
  end

  test "handles unknown messages without crashing" do
    pid =
      start_supervised!(
        {ConfigWatcher, service: :dns, handler: fn _k, _v -> :ok end, name: :test_cw_unknown}
      )

    send(pid, :unexpected_message)
    Process.sleep(10)
    assert Process.alive?(pid)
  end
end
