defmodule YellowDog.Dns.ZoneReloaderTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.ZoneReloader

  test "starts and stops cleanly" do
    pid = start_supervised!(ZoneReloader)
    assert Process.alive?(pid)
  end

  test "handles zone change events" do
    pid = start_supervised!(ZoneReloader)

    send(pid, {:store_event, :put, "dns:zone:example.com", %{}})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "handles zone RR change events" do
    pid = start_supervised!(ZoneReloader)

    send(pid, {:store_event, :put, "dns:zone:example.com:rr:www:a", %{}})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "handles delete events" do
    pid = start_supervised!(ZoneReloader)

    send(pid, {:store_event, :delete, "dns:zone:example.com:rr:www:a", nil})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "ignores non-zone events" do
    pid = start_supervised!(ZoneReloader)

    send(pid, {:store_event, :put, "dhcp:lease:v4:aa:bb:cc:dd:ee:ff", %{}})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "handles unknown messages without crashing" do
    pid = start_supervised!(ZoneReloader)

    send(pid, :unexpected_message)
    Process.sleep(10)
    assert Process.alive?(pid)
  end
end
