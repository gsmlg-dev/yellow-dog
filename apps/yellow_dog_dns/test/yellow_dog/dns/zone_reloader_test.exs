defmodule YellowDog.Dns.ZoneReloaderTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.ZoneReloader

  test "starts and stops cleanly" do
    pid = start_supervised!(ZoneReloader)
    assert Process.alive?(pid)
  end

  test "handles zone change events" do
    pid = start_supervised!(ZoneReloader)

    send(pid, {:store_event, %{type: :put, key: "dns:zone:example.com", value: %{}}})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "handles zone RR change events" do
    pid = start_supervised!(ZoneReloader)

    send(pid, {:store_event, %{type: :put, key: "dns:zone:example.com:rr:www:a", value: %{}}})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "handles delete events" do
    pid = start_supervised!(ZoneReloader)

    send(pid, {:store_event, %{type: :delete, key: "dns:zone:example.com:rr:www:a", value: nil}})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "ignores non-zone events" do
    pid = start_supervised!(ZoneReloader)

    send(pid, {:store_event, %{type: :put, key: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff", value: %{}}})
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
