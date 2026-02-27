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
end
