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
end
