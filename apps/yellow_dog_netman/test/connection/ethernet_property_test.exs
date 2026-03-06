defmodule YellowDog.Netman.Connection.EthernetPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Connection.Ethernet
  alias YellowDog.Netman.Test.MockNetlink

  @moduletag :capture_log

  defp iface_gen do
    StreamData.string(:alphanumeric, min_length: 3, max_length: 10)
    |> StreamData.map(&("ep_" <> &1))
    |> StreamData.map(&String.slice(&1, 0, 15))
  end

  # Properties

  property "ethernet? always returns a boolean" do
    check all(iface <- StreamData.string(:printable, min_length: 0, max_length: 64)) do
      assert is_boolean(Ethernet.ethernet?(iface))
    end
  end

  property "carrier? always returns a boolean" do
    check all(iface <- StreamData.string(:printable, min_length: 0, max_length: 64)) do
      assert is_boolean(Ethernet.carrier?(iface))
    end
  end

  property "mtu always returns a positive integer or nil" do
    check all(iface <- StreamData.string(:printable, min_length: 0, max_length: 64)) do
      result = Ethernet.mtu(iface)
      assert is_nil(result) or (is_integer(result) and result > 0)
    end
  end

  property "unknown interface always returns false for ethernet? and carrier?" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      # Use a prefix that is never registered by any test setup
      unknown = "unk_eth_#{iface}"
      assert Ethernet.ethernet?(unknown) == false
      assert Ethernet.carrier?(unknown) == false
    end
  end

  property "unknown interface always returns nil for mtu" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      assert Ethernet.mtu("unk_mtu_#{iface}") == nil
    end
  end

  property "link with nil kind is always treated as ethernet" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, kind: nil)
      Process.sleep(50)
      assert Ethernet.ethernet?(iface) == true
    end
  end

  property "link with carrier: true always returns true for carrier?" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      assert Ethernet.carrier?(iface) == true
    end
  end

  property "mtu value in range [68,65535] is always preserved" do
    check all(
            iface <- iface_gen(),
            mtu <- StreamData.integer(68..65535)
          ) do
      MockNetlink.link_up(iface, mtu: mtu)
      Process.sleep(50)
      assert Ethernet.mtu(iface) == mtu
    end
  end

  property "link with 'veth' kind is always treated as ethernet" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, kind: "veth")
      Process.sleep(50)
      assert Ethernet.ethernet?(iface) == true
    end
  end

  property "link with non-ethernet kind is never treated as ethernet" do
    check all(
            iface <- iface_gen(),
            kind <- StreamData.member_of(["bridge", "bond", "loopback", "dummy", "tun"])
          ) do
      MockNetlink.link_up(iface, kind: kind)
      Process.sleep(50)
      assert Ethernet.ethernet?(iface) == false
    end
  end

  property "link with carrier: false always returns false for carrier?" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      assert Ethernet.carrier?(iface) == false
    end
  end

  property "link_removed causes ethernet? to return false" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      assert Ethernet.ethernet?(iface) == true

      MockNetlink.link_removed(iface)
      Process.sleep(50)
      assert Ethernet.ethernet?(iface) == false
    end
  end

  property "non-ethernet kind with carrier: true has carrier? true but ethernet? false" do
    check all(
            iface <- iface_gen(),
            kind <- StreamData.member_of(["bridge", "bond", "loopback", "dummy"])
          ) do
      MockNetlink.link_up(iface, carrier: true, kind: kind)
      Process.sleep(50)

      assert Ethernet.carrier?(iface) == true,
             "Expected carrier? true for #{kind} link with carrier:true"

      assert Ethernet.ethernet?(iface) == false,
             "Expected ethernet? false for #{kind} link"
    end
  end
end
