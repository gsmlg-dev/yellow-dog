defmodule YellowDog.Netman.Kernel.AddressManagerPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Kernel.AddressManager
  alias YellowDog.Netman.Test.MockNetlink

  # Generators

  defp ipv4_gen do
    gen all(
          a <- StreamData.integer(1..254),
          b <- StreamData.integer(0..255),
          c <- StreamData.integer(0..255),
          d <- StreamData.integer(1..254)
        ) do
      "#{a}.#{b}.#{c}.#{d}"
    end
  end

  defp ipv6_gen do
    gen all(
          a <- StreamData.integer(0x2001..0x2001),
          b <- StreamData.integer(0..0xFFFF),
          c <- StreamData.integer(0..0xFFFF),
          d <- StreamData.integer(1..0xFFFE)
        ) do
      "#{Integer.to_string(a, 16)}:#{Integer.to_string(b, 16)}:#{Integer.to_string(c, 16)}::#{Integer.to_string(d, 16)}"
    end
  end

  defp iface_gen do
    StreamData.string(:alphanumeric, min_length: 3, max_length: 12)
    |> StreamData.map(&("prop_am_" <> &1))
    |> StreamData.map(&String.slice(&1, 0, 15))
  end

  defp prefix_v4_gen, do: StreamData.integer(0..32)
  defp prefix_v6_gen, do: StreamData.integer(0..128)

  defp scope_gen do
    StreamData.member_of(["global", "link", "host", "other_scope"])
  end

  defp family_gen do
    StreamData.member_of(["inet", "inet6", "mpls"])
  end

  # Properties

  property "add then get always returns the address" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)
      assert Enum.any?(addresses, &(&1.address == addr))
    end
  end

  property "add then remove then get does not contain the address" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      cidr = "#{addr}/#{prefix}"
      MockNetlink.address_added(iface, cidr)
      Process.sleep(30)
      MockNetlink.address_removed(iface, cidr)
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)
      refute Enum.any?(addresses, &(&1.address == addr))
    end
  end

  property "duplicate adds are idempotent" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen(),
            repeats <- StreamData.integer(2..4)
          ) do
      cidr = "#{addr}/#{prefix}"

      for _i <- 1..repeats do
        MockNetlink.address_added(iface, cidr)
      end

      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)
      matching = Enum.filter(addresses, &(&1.address == addr))
      assert length(matching) == 1
    end
  end

  property "IPv4 CIDR prefix is stored correctly (0-32)" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)
      entry = Enum.find(addresses, &(&1.address == addr))
      assert entry != nil
      assert entry.prefix_len == prefix
      assert entry.family == :inet
    end
  end

  property "IPv6 CIDR prefix is stored correctly (0-128)" do
    check all(
            iface <- iface_gen(),
            addr <- ipv6_gen(),
            prefix <- prefix_v6_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}", family: "inet6")
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)
      entry = Enum.find(addresses, &(&1.address == addr))
      assert entry != nil
      assert entry.prefix_len == prefix
      assert entry.family == :inet6
    end
  end

  property "scope is always one of :global, :link, :host" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            scope <- scope_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/24", scope: scope)
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)
      entry = Enum.find(addresses, &(&1.address == addr))
      assert entry != nil
      assert entry.scope in [:global, :link, :host]
    end
  end

  property "family is always :inet or :inet6" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            family <- family_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/24", family: family)
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)
      entry = Enum.find(addresses, &(&1.address == addr))
      assert entry != nil
      assert entry.family in [:inet, :inet6]
    end
  end

  property "get_addresses never crashes for any interface name" do
    check all(iface <- StreamData.string(:printable, min_length: 0, max_length: 64)) do
      result = AddressManager.get_addresses(iface)
      assert is_list(result)
    end
  end
end
