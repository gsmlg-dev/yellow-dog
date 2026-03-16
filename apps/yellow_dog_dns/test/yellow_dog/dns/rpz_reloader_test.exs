defmodule YellowDog.Dns.RpzReloaderTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.RpzReloader

  test "starts and stops cleanly" do
    pid = start_supervised!(RpzReloader)
    assert Process.alive?(pid)
  end

  test "handles RPZ change events" do
    pid = start_supervised!(RpzReloader)

    send(pid, {:store_event, :put, "rpz:blocklist:evil.com", %{action: :nxdomain}})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "handles RPZ delete events" do
    pid = start_supervised!(RpzReloader)

    send(pid, {:store_event, :delete, "rpz:blocklist:evil.com", nil})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "ignores non-RPZ events" do
    pid = start_supervised!(RpzReloader)

    send(pid, {:store_event, :put, "dns:zone:example.com", %{}})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "handles unknown messages without crashing" do
    pid = start_supervised!(RpzReloader)

    send(pid, :unexpected_message)
    Process.sleep(10)
    assert Process.alive?(pid)
  end
end
