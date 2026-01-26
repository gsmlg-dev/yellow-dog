defmodule Abyss.UtilsTest do
  use ExUnit.Case, async: true

  alias Abyss.Utils

  describe "list_interfaces/0" do
    test "returns a list of interface names" do
      interfaces = Utils.list_interfaces()

      assert is_list(interfaces)
      # Should have at least loopback
      assert length(interfaces) > 0
      # All elements should be strings
      assert Enum.all?(interfaces, &is_binary/1)
    end

    test "includes loopback interface" do
      interfaces = Utils.list_interfaces()

      # Loopback is typically "lo" on Linux
      assert "lo" in interfaces or Enum.any?(interfaces, &String.contains?(&1, "loop"))
    end
  end

  describe "list_interfaces/1" do
    test "filters by :up flag" do
      up_interfaces = Utils.list_interfaces(only: :up)

      assert is_list(up_interfaces)
      # At least loopback should be up
      assert length(up_interfaces) > 0
    end

    test "filters by :loopback flag" do
      loopback_interfaces = Utils.list_interfaces(only: :loopback)

      assert is_list(loopback_interfaces)
      # Should have exactly one loopback (typically)
      assert length(loopback_interfaces) >= 1

      assert "lo" in loopback_interfaces or
               Enum.any?(loopback_interfaces, &String.contains?(&1, "loop"))
    end

    test "filters by :multicast flag" do
      multicast_interfaces = Utils.list_interfaces(only: :multicast)

      assert is_list(multicast_interfaces)
      # Multicast interfaces typically don't include loopback
    end

    test "filters by :broadcast flag" do
      broadcast_interfaces = Utils.list_interfaces(only: :broadcast)

      assert is_list(broadcast_interfaces)
    end

    test "filters by :down flag" do
      down_interfaces = Utils.list_interfaces(only: :down)

      assert is_list(down_interfaces)
      # Down interfaces shouldn't include loopback (which is always up)
      refute "lo" in down_interfaces
    end
  end

  describe "list_addresses/0" do
    test "returns a list of address info maps" do
      addresses = Utils.list_addresses()

      assert is_list(addresses)
      assert length(addresses) > 0

      # Each entry should have required keys
      Enum.each(addresses, fn addr ->
        assert Map.has_key?(addr, :interface)
        assert Map.has_key?(addr, :address)
        assert Map.has_key?(addr, :family)
        assert Map.has_key?(addr, :netmask)
        assert is_binary(addr.interface)
        assert is_tuple(addr.address)
        assert addr.family in [:inet, :inet6]
        assert is_tuple(addr.netmask)
      end)
    end

    test "includes loopback address 127.0.0.1" do
      addresses = Utils.list_addresses()

      loopback_v4 =
        Enum.find(addresses, fn addr ->
          addr.address == {127, 0, 0, 1}
        end)

      assert loopback_v4 != nil
      assert loopback_v4.family == :inet
      assert loopback_v4.netmask == {255, 0, 0, 0}
    end
  end

  describe "list_addresses/1" do
    test "filters by :inet family (IPv4 only)" do
      ipv4_addresses = Utils.list_addresses(family: :inet)

      assert is_list(ipv4_addresses)
      assert length(ipv4_addresses) > 0

      Enum.each(ipv4_addresses, fn addr ->
        assert addr.family == :inet
        assert tuple_size(addr.address) == 4
      end)
    end

    test "filters by :inet6 family (IPv6 only)" do
      ipv6_addresses = Utils.list_addresses(family: :inet6)

      assert is_list(ipv6_addresses)

      Enum.each(ipv6_addresses, fn addr ->
        assert addr.family == :inet6
        assert tuple_size(addr.address) == 8
      end)
    end

    test "filters by interface name" do
      addresses = Utils.list_addresses(interface: "lo")

      assert is_list(addresses)
      # All addresses should be from loopback
      Enum.each(addresses, fn addr ->
        assert addr.interface == "lo"
      end)
    end

    test "filters by :up flag" do
      addresses = Utils.list_addresses(only: :up)

      assert is_list(addresses)
      assert length(addresses) > 0
    end

    test "combines filters" do
      addresses = Utils.list_addresses(family: :inet, interface: "lo")

      assert is_list(addresses)
      assert length(addresses) >= 1

      Enum.each(addresses, fn addr ->
        assert addr.interface == "lo"
        assert addr.family == :inet
      end)
    end
  end

  describe "get_interface/1" do
    test "returns interface info for existing interface" do
      assert {:ok, info} = Utils.get_interface("lo")

      assert info.name == "lo"
      assert is_list(info.flags)
      assert :up in info.flags
      assert :loopback in info.flags
      assert is_list(info.addresses)
      assert length(info.addresses) > 0
    end

    test "returns error for non-existent interface" do
      assert {:error, :enodev} = Utils.get_interface("nonexistent_interface_xyz")
    end

    test "interface info includes addresses without interface key" do
      {:ok, info} = Utils.get_interface("lo")

      Enum.each(info.addresses, fn addr ->
        refute Map.has_key?(addr, :interface)
        assert Map.has_key?(addr, :address)
        assert Map.has_key?(addr, :family)
        assert Map.has_key?(addr, :netmask)
      end)
    end
  end

  describe "get_interface_addresses/1" do
    test "returns addresses for existing interface" do
      assert {:ok, addresses} = Utils.get_interface_addresses("lo")

      assert is_list(addresses)
      assert length(addresses) > 0

      Enum.each(addresses, fn addr ->
        refute Map.has_key?(addr, :interface)
        assert Map.has_key?(addr, :address)
        assert Map.has_key?(addr, :family)
      end)
    end

    test "filters by family" do
      assert {:ok, addresses} = Utils.get_interface_addresses("lo", family: :inet)

      Enum.each(addresses, fn addr ->
        assert addr.family == :inet
      end)
    end

    test "returns error for non-existent interface" do
      assert {:error, :enodev} = Utils.get_interface_addresses("nonexistent_interface")
    end
  end

  describe "get_ipv4_address/1" do
    test "returns IPv4 address for loopback" do
      assert {:ok, addr} = Utils.get_ipv4_address("lo")

      assert addr == {127, 0, 0, 1}
    end

    test "returns error for non-existent interface" do
      assert {:error, :enodev} = Utils.get_ipv4_address("nonexistent_interface")
    end
  end

  describe "get_ipv6_address/1" do
    test "returns IPv6 address for loopback" do
      result = Utils.get_ipv6_address("lo")

      case result do
        {:ok, addr} ->
          # IPv6 loopback is ::1
          assert addr == {0, 0, 0, 0, 0, 0, 0, 1}

        {:error, :enodev} ->
          # Some systems may not have IPv6 configured
          assert true
      end
    end

    test "returns error for non-existent interface" do
      assert {:error, :enodev} = Utils.get_ipv6_address("nonexistent_interface")
    end
  end

  describe "get_hwaddr/1" do
    test "returns hardware address for loopback" do
      assert {:ok, hwaddr} = Utils.get_hwaddr("lo")

      assert is_list(hwaddr)
      assert length(hwaddr) == 6
      # Loopback typically has all zeros
      assert hwaddr == [0, 0, 0, 0, 0, 0]
    end

    test "returns error for non-existent interface" do
      assert {:error, :enodev} = Utils.get_hwaddr("nonexistent_interface")
    end
  end

  describe "format_hwaddr/1" do
    test "formats hardware address with colons" do
      assert Utils.format_hwaddr([0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]) == "00:1a:2b:3c:4d:5e"
    end

    test "formats all-zero address" do
      assert Utils.format_hwaddr([0, 0, 0, 0, 0, 0]) == "00:00:00:00:00:00"
    end

    test "formats all-ff address" do
      assert Utils.format_hwaddr([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == "ff:ff:ff:ff:ff:ff"
    end
  end

  describe "format_address/1" do
    test "formats IPv4 address" do
      assert Utils.format_address({192, 168, 1, 10}) == "192.168.1.10"
      assert Utils.format_address({127, 0, 0, 1}) == "127.0.0.1"
      assert Utils.format_address({0, 0, 0, 0}) == "0.0.0.0"
      assert Utils.format_address({255, 255, 255, 255}) == "255.255.255.255"
    end

    test "formats IPv6 loopback address" do
      assert Utils.format_address({0, 0, 0, 0, 0, 0, 0, 1}) == "::1"
    end

    test "formats IPv6 address with zero compression" do
      # fe80::1
      result = Utils.format_address({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert result == "fe80::1"
    end

    test "formats full IPv6 address" do
      result =
        Utils.format_address({0x2001, 0x0DB8, 0x85A3, 0x0000, 0x0000, 0x8A2E, 0x0370, 0x7334})

      # Erlang inet.ntoa uses zero compression
      assert String.contains?(result, "2001") and String.contains?(result, "7334")
    end
  end
end
