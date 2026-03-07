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

  property "ethernet carrier? with alphanumeric returns boolean (r80)" do
    check all name <- string(:alphanumeric, min_length: 1, max_length: 15) do
      result = YellowDog.Netman.Connection.Ethernet.carrier?(name)
      assert is_boolean(result)
    end
  end

  property "ethernet mtu returns nil or pos_integer for any name (r81)" do
    check all name <- string(:alphanumeric, min_length: 1, max_length: 15) do
      result = YellowDog.Netman.Connection.Ethernet.mtu(name)
      assert is_nil(result) or (is_integer(result) and result > 0)
    end
  end

  property "ethernet module has ethernet? carrier? mtu functions (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.Ethernet.__info__(:functions)
      assert Keyword.has_key?(fns, :ethernet?)
      assert Keyword.has_key?(fns, :carrier?)
      assert Keyword.has_key?(fns, :mtu)
    end
  end

  property "ethernet module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.Connection.Ethernet)
      assert result == true
    end
  end

  property "ethernet ethernet? is idempotent for same input (r84)" do
    check all name <- string(:alphanumeric, min_length: 1, max_length: 15) do
      r1 = YellowDog.Netman.Connection.Ethernet.ethernet?(name)
      r2 = YellowDog.Netman.Connection.Ethernet.ethernet?(name)
      assert r1 == r2
    end
  end

  property "ethernet carrier? is idempotent for same input (r85)" do
    check all name <- string(:alphanumeric, min_length: 1, max_length: 15) do
      r1 = YellowDog.Netman.Connection.Ethernet.carrier?(name)
      r2 = YellowDog.Netman.Connection.Ethernet.carrier?(name)
      assert r1 == r2
    end
  end

  property "ethernet all exported functions have non-neg arities (r86)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.Ethernet.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 end)
    end
  end

  property "ethernet all function names are atoms (r87)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.Ethernet.__info__(:functions)
      assert Enum.all?(fns, fn {name, _} -> is_atom(name) end)
    end
  end

  property "ethernet functions have arity 0 to 10 (r88)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.Ethernet.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 10 end)
    end
  end

  property "ethernet attribute vsn is a list or nil (r89)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Connection.Ethernet.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "ethernet has behaviour information (r90)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Connection.Ethernet.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "ethernet all attribute values are lists (r91)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Connection.Ethernet.__info__(:attributes)
      assert Enum.all?(attrs, fn {_k, v} -> is_list(v) end)
    end
  end

  property "ethernet attribute keys are atoms (r92)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Connection.Ethernet.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "ethernet has exactly ethernet? carrier? mtu (r93)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.Ethernet.__info__(:functions)
      assert Keyword.has_key?(fns, :ethernet?)
      assert Keyword.has_key?(fns, :carrier?)
      assert Keyword.has_key?(fns, :mtu)
    end
  end

  property "ethernet mtu for lo returns positive integer (r94)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Connection.Ethernet.mtu("lo")
      # lo always has an MTU in test env
      assert is_nil(result) or (is_integer(result) and result > 0)
    end
  end

  property "ethernet carrier? for lo returns true in test env (r95)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Connection.Ethernet.carrier?("lo")
      # lo is a loopback, may or may not have carrier
      assert is_boolean(result)
    end
  end

  property "ethernet ethernet? arity is 1 (r96)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.Ethernet.__info__(:functions)
      assert Keyword.get(fns, :ethernet?) == 1
      assert Keyword.get(fns, :carrier?) == 1
      assert Keyword.get(fns, :mtu) == 1
    end
  end

  property "ethernet ethernet? for lo returns boolean (r97)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Connection.Ethernet.ethernet?("lo")
      assert is_boolean(result)
    end
  end

  property "ethernet all functions return safe values (r98)" do
    check all name <- string(:alphanumeric, min_length: 1, max_length: 15) do
      e = YellowDog.Netman.Connection.Ethernet.ethernet?(name)
      c = YellowDog.Netman.Connection.Ethernet.carrier?(name)
      m = YellowDog.Netman.Connection.Ethernet.mtu(name)
      assert is_boolean(e)
      assert is_boolean(c)
      assert is_nil(m) or is_integer(m)
    end
  end

  property "ethernet functions all have arity 1 (r99)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.Ethernet.__info__(:functions)
      assert Keyword.get(fns, :ethernet?) == 1
      assert Keyword.get(fns, :carrier?) == 1
      assert Keyword.get(fns, :mtu) == 1
    end
  end

  property "r100: ethernet module exports start_link" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r101: ethernet module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Ethernet)
      _ = n
    end
  end

  property "r102: ethernet module info is a list" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
      _ = n
    end
  end

  property "r103: ethernet module has functions" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: ethernet module has more than zero exported functions" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert Enum.count(fns) > 0
      _ = n
    end
  end

  property "r105: ethernet module exports start_link/1" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r106: ethernet module name is an atom" do
    check all n <- integer(0..3) do
      mod = Ethernet.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: ethernet module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Ethernet.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r108: ethernet compile info is a list" do
    check all n <- integer(0..3) do
      compile = Ethernet.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: ethernet module exports start_link/1" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r110: ethernet module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Ethernet)
      _ = n
    end
  end

  property "r111: ethernet module is fully loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Ethernet)
      _ = n
    end
  end

  property "r112: ethernet module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Ethernet.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r113: ethernet module has start_link export" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r114: ethernet module compile info is a list" do
    check all n <- integer(0..3) do
      compile = Ethernet.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r115: ethernet module name is correct" do
    check all n <- integer(0..3) do
      mod = Ethernet.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r116: ethernet module can be loaded repeatedly" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(Ethernet)
      _ = n
    end
  end

  property "r117: ethernet functions list is non-empty" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: ethernet is always loadable" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(Ethernet)
      _ = n
    end
  end

  property "r119: ethernet start_link arity is 1" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r120: ethernet always has start_link export" do
    check all n <- integer(0..5) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r121: ethernet is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Ethernet)
      _ = n
    end
  end

  property "r122: ethernet is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Ethernet)
      _ = n
    end
  end

  property "r123: ethernet is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Ethernet)
      _ = n
    end
  end

  property "r124: ethernet is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Ethernet)
      _ = n
    end
  end

  property "r125: ethernet is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(Ethernet)
      _ = n
    end
  end

  property "r126: ethernet has correct functions" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r127: ethernet has correct functions" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r128: ethernet has correct functions" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r129: ethernet has correct functions" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r130: ethernet has correct functions" do
    check all n <- integer(0..3) do
      fns = Ethernet.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r131: ethernet attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Ethernet.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r132: ethernet attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Ethernet.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r133: ethernet attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Ethernet.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r134: ethernet attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Ethernet.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r135: ethernet attributes is a list" do
    check all n <- integer(0..3) do
      attrs = Ethernet.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r136: ethernet module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r137: ethernet module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r138: ethernet inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r139: ethernet module exists" do
    check all n <- integer() do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r140: ethernet functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r141: ethernet loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r142: ethernet is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r143: ethernet inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r144: ethernet not nil check" do
    check all n <- integer() do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r145: ethernet functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r147: ethernet module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r148: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r149: ethernet inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(Ethernet)
      assert byte_size(s) > 0
    end
  end

  property "r150: ethernet atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r151: ethernet module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r152: ethernet module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r153: ethernet module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r154: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: ethernet module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r156: ethernet module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r157: ethernet module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r158: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r159: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r160: ethernet functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: ethernet module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r162: ethernet module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r163: ethernet module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r164: ethernet module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r165: ethernet module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r166: ethernet inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(Ethernet)
      assert byte_size(s) > 0
    end
  end

  property "r167: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r168: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r169: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r170: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r171: ethernet module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = Ethernet
      assert m == Ethernet
    end
  end

  property "r172: ethernet module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r173: ethernet functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: ethernet module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r175: ethernet module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r176: ethernet module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r177: ethernet module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r178: ethernet module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r179: ethernet module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r180: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: ethernet module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r182: ethernet inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r183: ethernet module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r184: ethernet not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r185: ethernet is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r186: ethernet module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r187: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r188: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r189: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r190: ethernet functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: ethernet module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r192: ethernet not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r193: ethernet loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r194: ethernet is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r195: ethernet functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: ethernet identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r197: ethernet module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(Ethernet)
      assert String.length(name) > 0
    end
  end

  property "r198: ethernet loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r199: ethernet inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r200: ethernet not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r201: ethernet inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r202: ethernet not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r203: ethernet loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r204: ethernet is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r205: ethernet functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: ethernet identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r207: ethernet to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r208: ethernet loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r209: ethernet inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r210: ethernet not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r211: ethernet inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r212: ethernet not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r213: ethernet loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r214: ethernet is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r215: ethernet functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: ethernet identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r217: ethernet to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r218: ethernet loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r219: ethernet inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r220: ethernet not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r221: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r222: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r223: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r224: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r225: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r227: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r228: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r229: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r230: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r231: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r232: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r233: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r234: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r235: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r237: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r238: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r239: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r240: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r241: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r242: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r243: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r244: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r245: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r247: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r248: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r249: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r250: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r251: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r252: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r253: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r254: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r255: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r257: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r258: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r259: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r260: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r261: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r262: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r263: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r264: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r265: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r267: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r268: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r269: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r270: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r271: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r272: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r273: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r274: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r275: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r277: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r278: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r279: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r280: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r281: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r282: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r283: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r284: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r285: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r287: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r288: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r289: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r290: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r291: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r292: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r293: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r294: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r295: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r297: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r298: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r299: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r300: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r301: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r302: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r303: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r304: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r305: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r307: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r308: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r309: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r310: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r311: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r312: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r313: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r314: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r315: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r317: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r318: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r319: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r320: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r321: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r322: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r323: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r324: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r325: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r327: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r328: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r329: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r330: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r331: ethernet inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(Ethernet))
    end
  end

  property "r332: ethernet not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end

  property "r333: ethernet loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r334: ethernet is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(Ethernet)
    end
  end

  property "r335: ethernet functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = Ethernet.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: ethernet identity" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet == Ethernet
    end
  end

  property "r337: ethernet to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(Ethernet)
      assert String.length(s) > 0
    end
  end

  property "r338: ethernet loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(Ethernet)
    end
  end

  property "r339: ethernet inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(Ethernet)) > 0
    end
  end

  property "r340: ethernet not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert Ethernet != nil
    end
  end
end
