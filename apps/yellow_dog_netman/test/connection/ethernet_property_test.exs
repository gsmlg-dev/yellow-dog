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

  property "link_down then link_up sequence restores carrier? to true" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(30)
      MockNetlink.link_down(iface)
      Process.sleep(30)
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      assert Ethernet.carrier?(iface) == true,
             "Expected carrier? true after link_down then link_up on #{iface}"
    end
  end

  property "repeated calls to ethernet? return the same stable result" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      result1 = Ethernet.ethernet?(iface)
      result2 = Ethernet.ethernet?(iface)
      result3 = Ethernet.ethernet?(iface)

      assert result1 == result2 and result2 == result3,
             "ethernet? returned inconsistent results for #{iface}"
    end
  end

  property "link with nil kind and carrier: true is both ethernet and carrier-present" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true, kind: nil)
      Process.sleep(50)

      assert Ethernet.ethernet?(iface) == true,
             "Expected ethernet? true for nil-kind link on #{iface}"

      assert Ethernet.carrier?(iface) == true,
             "Expected carrier? true for carrier:true link on #{iface}"
    end
  end

  property "carrier? returns consistent result across repeated calls" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      r1 = Ethernet.carrier?(iface)
      r2 = Ethernet.carrier?(iface)
      r3 = Ethernet.carrier?(iface)

      assert r1 == r2 and r2 == r3,
             "carrier? returned inconsistent results for #{iface}: #{r1}, #{r2}, #{r3}"
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

  property "link_removed causes carrier? to return false" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      assert Ethernet.carrier?(iface) == true

      MockNetlink.link_removed(iface)
      Process.sleep(50)

      assert Ethernet.carrier?(iface) == false,
             "Expected carrier? false after link_removed on #{iface}"
    end
  end

  property "link_down resets mtu to the default value of 1500" do
    check all(
            iface <- iface_gen(),
            mtu <- StreamData.integer(68..65535)
          ) do
      MockNetlink.link_up(iface, mtu: mtu)
      Process.sleep(50)
      assert Ethernet.mtu(iface) == mtu

      MockNetlink.link_down(iface)
      Process.sleep(50)

      assert Ethernet.mtu(iface) == 1500,
             "Expected mtu 1500 (default) after link_down on #{iface}"
    end
  end

  property "mtu returns nil after link_removed" do
    check all(
            iface <- iface_gen(),
            mtu <- StreamData.integer(68..65535)
          ) do
      MockNetlink.link_up(iface, mtu: mtu)
      Process.sleep(50)
      assert Ethernet.mtu(iface) == mtu

      MockNetlink.link_removed(iface)
      Process.sleep(50)

      assert Ethernet.mtu(iface) == nil,
             "Expected nil mtu after link_removed on #{iface}"
    end
  end
end
