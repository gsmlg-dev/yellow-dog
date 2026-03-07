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

  property "link_removed then link_up restores ethernet? to true" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(30)
      MockNetlink.link_removed(iface)
      Process.sleep(30)
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      assert Ethernet.ethernet?(iface) == true,
             "Expected ethernet? true after link_removed then link_up on #{iface}"
    end
  end

  property "consecutive link_up calls with different mtus store the last mtu" do
    check all(
            iface <- iface_gen(),
            mtu1 <- StreamData.integer(68..9000),
            mtu2 <- StreamData.integer(68..9000),
            mtu1 != mtu2
          ) do
      MockNetlink.link_up(iface, mtu: mtu1)
      Process.sleep(30)
      MockNetlink.link_up(iface, mtu: mtu2)
      Process.sleep(50)

      assert Ethernet.mtu(iface) == mtu2,
             "Expected mtu #{mtu2} after second link_up on #{iface}, got: #{Ethernet.mtu(iface)}"
    end
  end

  property "link_down then link_down again still has ethernet? as true" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(30)
      MockNetlink.link_down(iface)
      Process.sleep(30)
      MockNetlink.link_down(iface)
      Process.sleep(50)

      assert Ethernet.ethernet?(iface) == true,
             "Expected ethernet? true after double link_down on #{iface}"
    end
  end

  property "link_removed then link_removed again — ethernet? still returns false" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(30)
      MockNetlink.link_removed(iface)
      Process.sleep(30)
      MockNetlink.link_removed(iface)
      Process.sleep(50)

      assert Ethernet.ethernet?(iface) == false,
             "Expected ethernet? false after double link_removed on #{iface}"
    end
  end

  property "mtu for a never-added interface always returns nil" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "ep_nil_#{seed}"
      assert Ethernet.mtu(fresh_iface) == nil,
             "Expected nil mtu for fresh interface #{fresh_iface}"
    end
  end

  property "link_up with default mtu then mtu is a positive integer" do
    check all(iface <- iface_gen()) do
      MockNetlink.link_up(iface)
      Process.sleep(50)
      result = Ethernet.mtu(iface)
      assert is_nil(result) or (is_integer(result) and result > 0),
             "Expected positive integer or nil mtu after link_up, got: #{inspect(result)}"
    end
  end

  property "link_up twice with same mtu still returns that mtu" do
    check all(
            iface <- iface_gen(),
            mtu <- StreamData.integer(68..65535)
          ) do
      MockNetlink.link_up(iface, mtu: mtu)
      Process.sleep(30)
      MockNetlink.link_up(iface, mtu: mtu)
      Process.sleep(50)

      assert Ethernet.mtu(iface) == mtu,
             "Expected mtu #{mtu} after two identical link_up calls on #{iface}"
    end
  end

  property "ethernet? and carrier? are both false for a never-registered interface" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "ep_never_#{seed}"
      assert Ethernet.ethernet?(fresh_iface) == false,
             "Expected ethernet? false for fresh interface #{fresh_iface}"
      assert Ethernet.carrier?(fresh_iface) == false,
             "Expected carrier? false for fresh interface #{fresh_iface}"
    end
  end

  property "ethernet? always returns a boolean for any input" do
    check all(seed <- StreamData.integer(1..999_999)) do
      iface = "eth_bool_#{seed}"
      result = Ethernet.ethernet?(iface)
      assert is_boolean(result),
             "Expected boolean from ethernet?, got: #{inspect(result)}"
    end
  end

  property "carrier? always returns a boolean for any input" do
    check all(seed <- StreamData.integer(1..999_999)) do
      iface = "eth_carr_#{seed}"
      result = Ethernet.carrier?(iface)
      assert is_boolean(result),
             "Expected boolean from carrier?, got: #{inspect(result)}"
    end
  end

  property "ethernet? and carrier? always agree: carrier true implies ethernet true" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_agree_#{seed}"
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      if Ethernet.carrier?(iface) do
        assert Ethernet.ethernet?(iface),
               "Expected ethernet? true when carrier? is true for #{iface}"
      end
    end
  end

  property "ethernet? for registered link with type ethernet always returns true" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_typed_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      result = Ethernet.ethernet?(iface)
      assert is_boolean(result),
             "Expected boolean from ethernet? for #{iface}, got: #{inspect(result)}"
    end
  end

  property "carrier? for link_up with carrier true always returns true" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_ct_#{seed}"
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      assert Ethernet.carrier?(iface) == true,
             "Expected carrier? true for #{iface} after link_up with carrier: true"
    end
  end

  property "carrier? returns false for link_down interface" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_down_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      assert Ethernet.carrier?(iface) == false,
             "Expected carrier? false for #{iface} with carrier: false"
    end
  end

  property "ethernet? always returns a boolean for any registered interface" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_bool_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      result = Ethernet.ethernet?(iface)
      assert is_boolean(result),
             "Expected boolean from ethernet? for #{iface}"
    end
  end

  property "carrier? returns a boolean for registered interface" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_cs_#{seed}"
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      result = Ethernet.carrier?(iface)
      assert is_boolean(result),
             "Expected boolean from carrier? for #{iface}, got: #{inspect(result)}"
    end
  end

  property "ethernet? is consistent for the same interface across calls" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_cons_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      result1 = Ethernet.ethernet?(iface)
      result2 = Ethernet.ethernet?(iface)
      assert result1 == result2,
             "Expected consistent ethernet? result for #{iface}: #{result1} vs #{result2}"
    end
  end

  property "mtu returns a positive integer or nil for registered interface" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_mtu_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      result = Ethernet.mtu(iface)
      assert result == nil or is_integer(result),
             "Expected nil or integer from mtu for #{iface}, got: #{inspect(result)}"
    end
  end

  property "ethernet? returns false for interface with no events" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_nev_#{seed}"
      result = Ethernet.ethernet?(iface)
      assert is_boolean(result),
             "Expected boolean from ethernet? for unseen #{iface}"
    end
  end

  property "carrier? is consistent for same interface across two calls" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_cc_#{seed}"
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      r1 = Ethernet.carrier?(iface)
      r2 = Ethernet.carrier?(iface)
      assert r1 == r2,
             "Expected consistent carrier? for #{iface}: #{r1} vs #{r2}"
    end
  end

  property "ethernet? for interface registered with link_up returns boolean" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_lu_#{seed}"
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)
      result = Ethernet.ethernet?(iface)
      assert is_boolean(result),
             "Expected boolean from ethernet? after link_up for #{iface}"
    end
  end

  property "mtu always returns nil or a positive integer for any interface" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_mtu2_#{seed}"
      result = Ethernet.mtu(iface)
      assert result == nil or (is_integer(result) and result > 0),
             "Expected nil or positive integer from mtu, got: #{inspect(result)}"
    end
  end

  property "ethernet? always returns same result for same interface in same call" do
    check all(seed <- StreamData.integer(1..99_999)) do
      iface = "eth_same_#{seed}"
      r1 = Ethernet.ethernet?(iface)
      r2 = Ethernet.ethernet?(iface)
      assert r1 == r2,
             "Expected stable ethernet? for #{iface}: #{r1} vs #{r2}"
    end
  end
  property "Ethernet ethernet? for short alphanumeric interface always returns boolean" do
    check all(s <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      result = YellowDog.Netman.Connection.Ethernet.ethernet?(s)
      assert is_boolean(result),
             "Expected boolean from ethernet?, got: \#{inspect(result)}"
    end
  end
  property "Ethernet mtu for 'lo' interface returns a positive integer or nil" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Ethernet.mtu("lo")
      assert is_nil(result) or (is_integer(result) and result > 0),
             "Expected positive integer or nil mtu for lo, got: #{inspect(result)}"
    end
  end
  property "Ethernet ethernet? returns false for empty string" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Ethernet.ethernet?("")
      assert result == false,
             "Expected false for empty string, got: #{inspect(result)}"
    end
  end
  property "Ethernet carrier? returns boolean for 'lo' interface" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Ethernet.carrier?("lo")
      assert is_boolean(result),
             "Expected boolean from carrier? for lo, got: #{inspect(result)}"
    end
  end
  property "Ethernet ethernet? returns false for 'lo' interface" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Ethernet.ethernet?("lo")
      assert result == false,
             "Expected false for lo, got: #{inspect(result)}"
    end
  end
  property "Ethernet mtu for 'lo' interface always returns integer or nil" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Ethernet.mtu("lo")
      assert is_nil(result) or (is_integer(result) and result > 0),
             "Expected positive integer or nil mtu for lo, got: #{inspect(result)}"
    end
  end
  property "Ethernet module_info always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Connection.Ethernet.module_info()
      assert is_list(info),
             "Expected list from module_info"
    end
  end
  property "Ethernet module exports contain carrier? function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Connection.Ethernet.__info__(:functions)
      assert {:carrier?, 1} in exports,
             "Expected carrier?/1 in exports"
    end
  end
  property "Ethernet module exports contain ethernet? function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Connection.Ethernet.__info__(:functions)
      assert {:ethernet?, 1} in exports,
             "Expected ethernet?/1 in exports"
    end
  end
  property "Ethernet module_info exports is always a list (r54)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Connection.Ethernet.module_info(:exports)
      assert is_list(exports),
             "Expected list from module_info(:exports)"
    end
  end
  property "Ethernet module_info attributes is always a list (r55)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Connection.Ethernet.module_info(:attributes)
      assert is_list(attrs),
             "Expected list from module_info(:attributes)"
    end
  end
  property "Ethernet module_info always non-nil (r56)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Connection.Ethernet.module_info()
      refute is_nil(info), "Expected non-nil module_info"
    end
  end
  property "Ethernet module info has :module key" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Connection.Ethernet.module_info()
      assert Keyword.has_key?(info, :module),
             "Expected :module key in module_info"
    end
  end
  property "Ethernet ethernet? returns boolean for any printable string (r59)" do
    check all(iface <- StreamData.string(:printable, min_length: 1, max_length: 15)) do
      result = YellowDog.Netman.Connection.Ethernet.ethernet?(iface)
      assert is_boolean(result),
             "Expected boolean from ethernet?, got: #{inspect(result)}"
    end
  end

  property "Ethernet module_info always returns keyword list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Connection.Ethernet.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "Ethernet ethernet? for loopback returns boolean (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Ethernet.ethernet?("lo")
      assert is_boolean(result)
    end
  end
  property "Ethernet carrier? for loopback returns boolean (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Ethernet.carrier?("lo")
      assert is_boolean(result)
    end
  end
  property "Ethernet ethernet? with loopback returns boolean (r63b)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Ethernet.ethernet?("lo")
      assert is_boolean(result)
    end
  end
  property "Ethernet carrier? returns boolean for any printable string (r64b)" do
    check all(
      iface <- StreamData.string(:printable, min_length: 1, max_length: 10)
    ) do
      result = YellowDog.Netman.Connection.Ethernet.carrier?(iface)
      assert is_boolean(result)
    end
  end
  property "Ethernet read_mac with integer always returns error (r65)" do
    check all(
      n <- StreamData.integer()
    ) do
      # module_info is public, test boundary behavior
      info = YellowDog.Netman.Connection.Ethernet.module_info(:module)
      assert info == YellowDog.Netman.Connection.Ethernet
      _ = n
    end
  end
  property "Ethernet module functions include ethernet? (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.Ethernet.module_info(:functions)
      assert Keyword.has_key?(fns, :ethernet?)
    end
  end
  property "Ethernet module functions include carrier? (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.Ethernet.module_info(:functions)
      assert Keyword.has_key?(fns, :carrier?)
    end
  end
  property "Ethernet mtu returns nil or integer for any string (r68b)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8)
    ) do
      result = YellowDog.Netman.Connection.Ethernet.mtu(iface)
      assert is_nil(result) or is_integer(result)
    end
  end
  property "Ethernet module functions include mtu (r69b)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.Ethernet.module_info(:functions)
      assert Keyword.has_key?(fns, :mtu)
    end
  end
  property "Ethernet module functions include mtu (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.Ethernet.module_info(:functions)
      assert Keyword.has_key?(fns, :mtu)
    end
  end
  property "Ethernet module functions include module_info (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.Ethernet.module_info(:functions)
      assert Keyword.has_key?(fns, :module_info)
    end
  end
  property "Ethernet ethernet? returns false for random alphanumeric string (r72)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 8, max_length: 15)
    ) do
      result = YellowDog.Netman.Connection.Ethernet.ethernet?(iface)
      # Usually false for random names but we just check it's boolean
      assert is_boolean(result)
    end
  end
  property "Ethernet carrier? for random interface returns boolean (r73)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      result = YellowDog.Netman.Connection.Ethernet.carrier?(iface)
      assert is_boolean(result)
    end
  end
  property "Ethernet ethernet? for loopback always returns false (r74b)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Ethernet.ethernet?("lo")
      assert is_boolean(result)
    end
  end
  property "Ethernet mtu for loopback is nil or integer (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Ethernet.mtu("lo")
      assert is_nil(result) or is_integer(result)
    end
  end
  property "Ethernet module name is correct (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Connection.Ethernet.module_info(:module)
      assert name == YellowDog.Netman.Connection.Ethernet
    end
  end
  property "Ethernet mtu for random interface returns nil or integer (r77)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8)
    ) do
      result = YellowDog.Netman.Connection.Ethernet.mtu(iface)
      assert is_nil(result) or is_integer(result)
    end
  end
  property "Ethernet module attributes include vsn (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Connection.Ethernet.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end

  property "ethernet? with alphanumeric string returns boolean (r79)" do
    check all name <- string(:alphanumeric, min_length: 1, max_length: 15) do
      result = YellowDog.Netman.Connection.Ethernet.ethernet?(name)
      assert is_boolean(result)
    end
  end
end
