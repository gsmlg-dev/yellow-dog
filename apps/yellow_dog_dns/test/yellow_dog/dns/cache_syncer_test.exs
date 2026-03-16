defmodule YellowDog.Dns.CacheSyncerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.CacheSyncer

  test "starts and stops cleanly" do
    pid = start_supervised!({CacheSyncer, warm_on_start: false, flush_interval_ms: 60_000})
    assert Process.alive?(pid)
  end

  test "schedules periodic flush" do
    pid =
      start_supervised!({CacheSyncer, warm_on_start: false, flush_interval_ms: 50})

    assert Process.alive?(pid)

    # Wait for at least one flush cycle
    Process.sleep(100)
    assert Process.alive?(pid)
  end

  test "handles unknown messages without crashing" do
    pid = start_supervised!({CacheSyncer, warm_on_start: false, flush_interval_ms: 60_000})
    send(pid, :unexpected_message)
    Process.sleep(10)
    assert Process.alive?(pid)
  end
end
