defmodule YellowDog.Netman.Kernel.SupervisorTest do
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.AddressManager
  alias YellowDog.Netman.Kernel.LinkMonitor
  alias YellowDog.Netman.Kernel.Netlink
  alias YellowDog.Netman.Kernel.RouteManager
  alias YellowDog.Netman.Test.MockNetlink

  describe "rest_for_one restart cascade" do
    test "crashing Netlink restarts all downstream monitors" do
      netlink_pid = Process.whereis(Netlink)
      link_pid = Process.whereis(LinkMonitor)
      addr_pid = Process.whereis(AddressManager)
      route_pid = Process.whereis(RouteManager)

      assert netlink_pid != nil
      assert link_pid != nil

      ref = Process.monitor(netlink_pid)
      Process.exit(netlink_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^netlink_pid, :killed}, 1000

      # Wait for supervisor to restart children
      Process.sleep(200)

      new_netlink = Process.whereis(Netlink)
      new_link = Process.whereis(LinkMonitor)
      new_addr = Process.whereis(AddressManager)
      new_route = Process.whereis(RouteManager)

      assert new_netlink != nil
      assert new_netlink != netlink_pid
      # rest_for_one: downstream children restart
      assert new_link != link_pid
      assert new_addr != addr_pid
      assert new_route != route_pid
    end

    test "crashing LinkMonitor does not restart Netlink" do
      netlink_pid = Process.whereis(Netlink)
      link_pid = Process.whereis(LinkMonitor)

      ref = Process.monitor(link_pid)
      Process.exit(link_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^link_pid, :killed}, 1000

      Process.sleep(200)

      # Netlink is upstream — should NOT restart
      assert Process.whereis(Netlink) == netlink_pid
      # LinkMonitor should be restarted
      assert Process.whereis(LinkMonitor) != link_pid
      assert Process.whereis(LinkMonitor) != nil
    end

    test "monitors recover state after restart" do
      iface = "restart_test_#{:rand.uniform(65535)}"
      MockNetlink.link_up(iface)
      MockNetlink.address_added(iface, "10.99.0.1/24")
      Process.sleep(50)

      assert LinkMonitor.get_link(iface) != nil
      assert Enum.any?(AddressManager.get_addresses(iface), &(&1.address == "10.99.0.1"))

      # Kill Netlink to trigger cascade restart
      netlink_pid = Process.whereis(Netlink)
      ref = Process.monitor(netlink_pid)
      Process.exit(netlink_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^netlink_pid, :killed}, 1000
      Process.sleep(200)

      # ETS tables recreated — old data gone, but monitors are alive and functional
      assert Process.whereis(AddressManager) != nil
      assert Process.whereis(LinkMonitor) != nil

      # New events can be processed after restart
      MockNetlink.link_up(iface)
      MockNetlink.address_added(iface, "10.99.0.2/24")
      Process.sleep(50)

      assert LinkMonitor.get_link(iface) != nil
      assert Enum.any?(AddressManager.get_addresses(iface), &(&1.address == "10.99.0.2"))
    end
  end
end
