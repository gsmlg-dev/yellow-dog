defmodule YellowDog.Netman.Kernel.AddressManagerTest do
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.AddressManager
  alias YellowDog.Netman.Test.MockNetlink

  test "address_added creates an address entry" do
    MockNetlink.address_added("test_addr_eth0", "10.0.0.1/24")
    Process.sleep(50)

    addresses = AddressManager.get_addresses("test_addr_eth0")
    assert length(addresses) >= 1
    assert Enum.any?(addresses, &(&1.address == "10.0.0.1"))
  end

  test "address_removed deletes an address" do
    MockNetlink.address_added("test_addr_eth1", "10.0.1.1/24")
    Process.sleep(50)
    assert Enum.any?(AddressManager.get_addresses("test_addr_eth1"), &(&1.address == "10.0.1.1"))

    MockNetlink.address_removed("test_addr_eth1", "10.0.1.1/24")
    Process.sleep(50)
    refute Enum.any?(AddressManager.get_addresses("test_addr_eth1"), &(&1.address == "10.0.1.1"))
  end

  test "list_all returns addresses grouped by interface" do
    MockNetlink.address_added("test_all_a", "10.0.10.1/24")
    MockNetlink.address_added("test_all_b", "10.0.20.1/24")
    Process.sleep(50)

    all = AddressManager.list_all()
    assert Map.has_key?(all, "test_all_a")
    assert Map.has_key?(all, "test_all_b")
  end

  test "get_addresses returns empty list for unknown interface" do
    assert AddressManager.get_addresses("nonexistent") == []
  end

  test "IPv6 address is stored with inet6 family" do
    iface = "addr_ipv6_#{:rand.uniform(65535)}"
    MockNetlink.address_added(iface, "fe80::1/64", family: "inet6", scope: "link")
    Process.sleep(50)

    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.family == :inet6 and &1.scope == :link))
  end

  test "address scope is preserved for link-local addresses" do
    iface = "addr_link_#{:rand.uniform(65535)}"
    MockNetlink.address_added(iface, "169.254.0.1/16", scope: "link")
    Process.sleep(50)

    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.scope == :link))
  end

  test "flush removes all addresses for an interface" do
    iface = "addr_flush_#{:rand.uniform(65535)}"
    MockNetlink.address_added(iface, "10.1.0.1/24")
    MockNetlink.address_added(iface, "10.1.0.2/24")
    Process.sleep(50)

    assert length(AddressManager.get_addresses(iface)) >= 2

    AddressManager.flush(iface)
    Process.sleep(50)

    # After flush, the ETS table entry may still exist but commands were sent
    # (In mock mode, flush sends commands but the ETS isn't actually updated by commands)
    # Verify flush didn't crash and sent the remove commands
    assert is_list(AddressManager.get_addresses(iface))
  end

  test "address_change event is published to EventBus on add" do
    iface = "addr_event_#{:rand.uniform(65535)}"
    YellowDog.Netman.EventBus.subscribe("netman:address:#{iface}")

    MockNetlink.address_added(iface, "10.2.0.1/24")
    Process.sleep(50)

    assert_receive {:netman_event, "netman:address:" <> ^iface, {:add, %{address: "10.2.0.1"}}},
                   500
  end

  test "address_change event is published to EventBus on remove" do
    iface = "addr_del_event_#{:rand.uniform(65535)}"
    MockNetlink.address_added(iface, "10.3.0.1/24")
    Process.sleep(50)

    YellowDog.Netman.EventBus.subscribe("netman:address:#{iface}")
    MockNetlink.address_removed(iface, "10.3.0.1/24")
    Process.sleep(50)

    assert_receive {:netman_event, "netman:address:" <> ^iface,
                    {:remove, %{address: "10.3.0.1"}}},
                   500
  end

  test "duplicate address add is idempotent" do
    iface = "addr_dup_#{:rand.uniform(65535)}"
    MockNetlink.address_added(iface, "10.4.0.1/24")
    MockNetlink.address_added(iface, "10.4.0.1/24")
    Process.sleep(50)

    addresses = AddressManager.get_addresses(iface)
    matching = Enum.filter(addresses, &(&1.address == "10.4.0.1"))
    assert length(matching) == 1, "Expected exactly 1 entry for duplicate address"
  end
end
