defmodule YellowDog.Netman.Connection.EthernetTest do
  use ExUnit.Case

  alias YellowDog.Netman.Connection.Ethernet
  alias YellowDog.Netman.Test.MockNetlink

  setup do
    # Use unique interface names per test to avoid ETS collisions
    :ok
  end

  describe "ethernet?/1" do
    test "returns true for link with nil kind" do
      MockNetlink.link_up("eth_test_nil", kind: nil)
      Process.sleep(50)
      assert Ethernet.ethernet?("eth_test_nil") == true
    end

    test "returns true for link with ethernet kind" do
      MockNetlink.link_up("eth_test_ether", kind: "ethernet")
      Process.sleep(50)
      assert Ethernet.ethernet?("eth_test_ether") == true
    end

    test "returns true for link with veth kind" do
      MockNetlink.link_up("eth_test_veth", kind: "veth")
      Process.sleep(50)
      assert Ethernet.ethernet?("eth_test_veth") == true
    end

    test "returns false for link with wifi kind" do
      MockNetlink.link_up("eth_test_wifi", kind: "wifi")
      Process.sleep(50)
      assert Ethernet.ethernet?("eth_test_wifi") == false
    end

    test "returns false for unknown interface" do
      assert Ethernet.ethernet?("eth_no_such_if") == false
    end
  end

  describe "carrier?/1" do
    test "returns true when carrier is present" do
      MockNetlink.link_up("carrier_test_up", carrier: true)
      Process.sleep(50)
      assert Ethernet.carrier?("carrier_test_up") == true
    end

    test "returns false when carrier is absent" do
      MockNetlink.link_up("carrier_test_down")
      Process.sleep(20)
      MockNetlink.link_down("carrier_test_down")
      Process.sleep(50)
      assert Ethernet.carrier?("carrier_test_down") == false
    end

    test "returns false for unknown interface" do
      assert Ethernet.carrier?("carrier_no_such") == false
    end
  end

  describe "mtu/1" do
    test "returns mtu value from link" do
      MockNetlink.link_up("mtu_test_9k", mtu: 9000)
      Process.sleep(50)
      assert Ethernet.mtu("mtu_test_9k") == 9000
    end

    test "returns default 1500 mtu" do
      MockNetlink.link_up("mtu_test_default", mtu: 1500)
      Process.sleep(50)
      assert Ethernet.mtu("mtu_test_default") == 1500
    end

    test "returns nil for unknown interface" do
      assert Ethernet.mtu("mtu_no_such") == nil
    end
  end
end
