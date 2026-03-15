defmodule YellowDog.Netman.Kernel.LinkMonitorTest do
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.LinkMonitor
  alias YellowDog.Netman.Test.MockNetlink

  setup do
    # Clear any existing test links
    # Links are stored in ETS — we rely on mock events
    :ok
  end

  test "link_up creates a link entry" do
    MockNetlink.link_up("test_eth0", index: 10, mtu: 9000)
    Process.sleep(50)

    link = LinkMonitor.get_link("test_eth0")
    assert link != nil
    assert link.interface == "test_eth0"
    assert link.index == 10
    assert link.mtu == 9000
    assert link.carrier == true
    assert link.state == :up
  end

  test "link_up stores mac and kind fields" do
    MockNetlink.link_up("test_mac_eth", mac: "11:22:33:44:55:66", kind: "veth")
    Process.sleep(50)

    link = LinkMonitor.get_link("test_mac_eth")
    assert link.mac == "11:22:33:44:55:66"
    assert link.kind == "veth"
  end

  test "link_down updates carrier to false" do
    MockNetlink.link_up("test_eth1")
    Process.sleep(50)
    MockNetlink.link_down("test_eth1")
    Process.sleep(50)

    link = LinkMonitor.get_link("test_eth1")
    assert link != nil
    assert link.carrier == false
    assert link.state == :down
  end

  test "link_removed deletes the link entry" do
    MockNetlink.link_up("test_eth2")
    Process.sleep(50)
    assert LinkMonitor.get_link("test_eth2") != nil

    MockNetlink.link_removed("test_eth2")
    Process.sleep(50)
    assert LinkMonitor.get_link("test_eth2") == nil
  end

  test "list_links returns all links" do
    MockNetlink.link_up("test_list_a")
    MockNetlink.link_up("test_list_b")
    Process.sleep(50)

    links = LinkMonitor.list_links()
    names = Enum.map(links, & &1.interface)
    assert "test_list_a" in names
    assert "test_list_b" in names
  end

  test "get_link returns nil for unknown interface" do
    assert LinkMonitor.get_link("nonexistent_iface") == nil
  end

  test "link event publishes to EventBus on add" do
    iface = "test_event_eth_#{:rand.uniform(65535)}"
    YellowDog.Netman.EventBus.subscribe("netman:link:#{iface}")

    MockNetlink.link_up(iface)
    Process.sleep(50)

    assert_receive {:netman_event, "netman:link:" <> ^iface, {:link_update, _}}, 500
  end

  test "link removed event publishes to EventBus" do
    iface = "test_del_eth_#{:rand.uniform(65535)}"
    MockNetlink.link_up(iface)
    Process.sleep(50)

    YellowDog.Netman.EventBus.subscribe("netman:link:#{iface}")
    MockNetlink.link_removed(iface)
    Process.sleep(50)

    assert_receive {:netman_event, "netman:link:" <> ^iface, {:removed, ^iface}}, 500
  end

  test "link state unknown is parsed as :unknown" do
    iface = "test_unknown_#{:rand.uniform(65535)}"

    # Manually send a raw link_change event with unknown state
    send(
      YellowDog.Netman.Kernel.Netlink,
      {:mock_event,
       %{
         "type" => "link_change",
         "action" => "add",
         "interface" => iface,
         "state" => "weird_state",
         "carrier" => false,
         "mtu" => 1500
       }}
    )

    Process.sleep(50)

    link = LinkMonitor.get_link(iface)
    assert link != nil
    assert link.state == :unknown
  end

  test "link change telemetry is emitted" do
    iface = "test_telem_lm_#{:rand.uniform(65535)}"
    test_pid = self()
    handler_id = {__MODULE__, :link_telem, :rand.uniform(1_000_000)}

    :telemetry.attach(
      handler_id,
      [:yellow_dog, :netman, :kernel, :link_change],
      fn _event, _measurements, meta, _config ->
        if meta.interface == iface, do: send(test_pid, {:link_telem, meta})
      end,
      nil
    )

    MockNetlink.link_up(iface)

    assert_receive {:link_telem, %{interface: ^iface, state: :up}}, 500

    :telemetry.detach(handler_id)
  end

  test "handle_info with unknown message is silently ignored" do
    pid = Process.whereis(LinkMonitor)
    send(pid, :unexpected_link_monitor_msg)
    Process.sleep(20)
    assert Process.alive?(pid)
  end

  test "string carrier value is coerced to boolean" do
    iface = "to_coerce#{:rand.uniform(65535)}"

    # Send a link event with string "true" carrier (simulating buggy netlink backend)
    pid = Process.whereis(LinkMonitor)

    send(
      pid,
      {:netlink_event,
       {:link_change,
        %{
          "action" => "add",
          "interface" => iface,
          "state" => "up",
          "carrier" => "true",
          "mtu" => 1500
        }}}
    )

    Process.sleep(50)

    links = LinkMonitor.list_links()
    link = Enum.find(links, &(&1.interface == iface))
    assert link != nil
    assert link.carrier == true
    assert is_boolean(link.carrier)
  end

  test "non-boolean carrier defaults to false" do
    iface = "to_coerce#{:rand.uniform(65535)}"
    pid = Process.whereis(LinkMonitor)

    send(
      pid,
      {:netlink_event,
       {:link_change,
        %{
          "action" => "add",
          "interface" => iface,
          "state" => "up",
          "carrier" => "false",
          "mtu" => 1500
        }}}
    )

    Process.sleep(50)

    links = LinkMonitor.list_links()
    link = Enum.find(links, &(&1.interface == iface))
    assert link != nil
    assert link.carrier == false
  end

  test "string mtu value is coerced to default" do
    iface = "to_mtu#{:rand.uniform(65535)}"
    pid = Process.whereis(LinkMonitor)

    send(
      pid,
      {:netlink_event,
       {:link_change,
        %{
          "action" => "add",
          "interface" => iface,
          "state" => "up",
          "carrier" => true,
          "mtu" => "not_a_number"
        }}}
    )

    Process.sleep(50)

    links = LinkMonitor.list_links()
    link = Enum.find(links, &(&1.interface == iface))
    assert link != nil
    assert link.mtu == 1500
  end

  test "malformed link event with no interface key is handled gracefully" do
    pid = Process.whereis(LinkMonitor)
    send(pid, {:netlink_event, {:link_change, %{"action" => "add", "state" => "up"}}})
    Process.sleep(20)
    assert Process.alive?(pid)
  end

  test "netlink event to EventBus publish latency is under threshold" do
    # PRD target: < 10ms in production.
    # Docker/CI overhead adds ~5-10ms, so we use 25ms threshold for test reliability.
    iface = "latency_#{:rand.uniform(65535)}"
    alias YellowDog.Netman.EventBus
    EventBus.subscribe("netman:link:#{iface}")

    start_time = System.monotonic_time(:microsecond)
    MockNetlink.link_up(iface, carrier: true)

    assert_receive {:netman_event, _, {:link_update, _}}, 1000
    end_time = System.monotonic_time(:microsecond)

    latency_us = end_time - start_time
    latency_ms = latency_us / 1000

    assert latency_ms < 25,
           "Netlink event latency was #{Float.round(latency_ms, 2)}ms, expected < 25ms"
  end
end
