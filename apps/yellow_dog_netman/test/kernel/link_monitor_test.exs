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
end
