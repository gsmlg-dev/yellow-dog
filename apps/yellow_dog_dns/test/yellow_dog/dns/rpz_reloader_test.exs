defmodule YellowDog.Dns.RpzReloaderTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.RpzReloader

  test "starts and stops cleanly" do
    pid = start_supervised!(RpzReloader)
    assert Process.alive?(pid)
  end

  test "handles RPZ change events" do
    pid = start_supervised!(RpzReloader)

    send(
      pid,
      {:store_event, %{type: :put, key: "rpz:blocklist:evil.com", value: %{action: :nxdomain}}}
    )

    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "handles RPZ delete events" do
    pid = start_supervised!(RpzReloader)

    send(pid, {:store_event, %{type: :delete, key: "rpz:blocklist:evil.com", value: nil}})
    Process.sleep(10)
    assert Process.alive?(pid)
  end

  test "ignores non-RPZ events" do
    pid = start_supervised!(RpzReloader)

    send(pid, {:store_event, %{type: :put, key: "dns:zone:example.com", value: %{}}})
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
