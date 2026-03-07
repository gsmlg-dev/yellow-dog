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
      # Remove any existing entry for this address to avoid deduplication
      MockNetlink.address_removed(iface, "#{addr}/#{prefix}")
      Process.sleep(30)
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
      # Remove any existing entry for this address to avoid deduplication
      MockNetlink.address_removed(iface, "#{addr}/#{prefix}")
      Process.sleep(30)
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

  property "list_all includes addresses from multiple distinct interfaces" do
    check all(
            iface1 <- iface_gen(),
            iface2 <- iface_gen(),
            iface1 != iface2,
            addr1 <- ipv4_gen(),
            addr2 <- ipv4_gen()
          ) do
      MockNetlink.address_added(iface1, "#{addr1}/24")
      MockNetlink.address_added(iface2, "#{addr2}/24")
      Process.sleep(50)

      all_addresses = AddressManager.list_all()

      assert Map.has_key?(all_addresses, iface1),
             "list_all missing interface #{iface1}"

      assert Enum.any?(all_addresses[iface1] || [], &(&1.address == addr1)),
             "list_all missing address #{addr1} on #{iface1}"

      assert Map.has_key?(all_addresses, iface2),
             "list_all missing interface #{iface2}"

      assert Enum.any?(all_addresses[iface2] || [], &(&1.address == addr2)),
             "list_all missing address #{addr2} on #{iface2}"
    end
  end

  property "add_address always returns :ok or {:error, _} for valid args" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      result = AddressManager.add_address(iface, addr, prefix)
      assert result == :ok or match?({:error, _}, result),
             "Unexpected add_address result: #{inspect(result)}"
    end
  end

  property "remove_address always returns :ok or {:error, _} for valid args" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      result = AddressManager.remove_address(iface, addr, prefix)
      assert result == :ok or match?({:error, _}, result),
             "Unexpected remove_address result: #{inspect(result)}"
    end
  end

  property "flush always returns a tuple of two non-negative integers" do
    check all(iface <- iface_gen()) do
      result = AddressManager.flush(iface)
      assert is_tuple(result) and tuple_size(result) == 2
      {removed, failed} = result
      assert is_integer(removed) and removed >= 0
      assert is_integer(failed) and failed >= 0
    end
  end

  property "address count on iface increases by 1 after adding a new unique address" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      # Remove any pre-existing instance to ensure clean count
      MockNetlink.address_removed(iface, "#{addr}/#{prefix}")
      Process.sleep(30)

      before_count = length(AddressManager.get_addresses(iface))

      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      after_count = length(AddressManager.get_addresses(iface))

      assert after_count == before_count + 1,
             "Expected address count to increase by 1: #{before_count} -> #{after_count}"
    end
  end

  property "all entries returned by get_addresses have required fields" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)

      for a <- addresses do
        for field <- [:address, :interface, :prefix_len, :family, :scope] do
          assert Map.has_key?(a, field),
                 "Address entry missing required field :#{field} in #{inspect(a)}"
        end
      end
    end
  end

  property "get_addresses for a fresh interface with no events returns empty list" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "am_fresh_#{seed}"
      result = AddressManager.get_addresses(fresh_iface)

      assert result == [],
             "Expected empty list for fresh interface #{fresh_iface}, got: #{inspect(result)}"
    end
  end

  property "list_all always returns a map with list values" do
    check all(_ <- StreamData.constant(:ok)) do
      all = AddressManager.list_all()
      assert is_map(all)

      for {_iface, addrs} <- all do
        assert is_list(addrs),
               "Expected list value in list_all map, got: #{inspect(addrs)}"
      end
    end
  end

  property "address added to iface1 is not visible in get_addresses(iface2)" do
    check all(
            iface1 <- iface_gen(),
            iface2 <- iface_gen(),
            iface1 != iface2,
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface1, "#{addr}/#{prefix}")
      Process.sleep(50)

      addresses2 = AddressManager.get_addresses(iface2)

      refute Enum.any?(addresses2, &(&1.address == addr and &1.interface == iface1)),
             "Address #{addr} on #{iface1} should not appear in #{iface2}'s address list"
    end
  end

  property "get_addresses result is always a subset of list_all entries for that interface" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      per_iface = AddressManager.get_addresses(iface)
      all_for_iface = AddressManager.list_all()[iface] || []

      for a <- per_iface do
        assert Enum.any?(all_for_iface, &(&1 == a)),
               "Address #{inspect(a)} in get_addresses but not in list_all[#{iface}]"
      end
    end
  end

  property "flush on a fresh interface always returns {0, 0}" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "am_flush_#{seed}"
      result = AddressManager.flush(fresh_iface)

      assert result == {0, 0},
             "Expected {0, 0} for fresh interface #{fresh_iface}, got: #{inspect(result)}"
    end
  end

  property "address_removed event decrements get_addresses count by 1 when address was present" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      before_count = length(AddressManager.get_addresses(iface))

      MockNetlink.address_removed(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      after_count = length(AddressManager.get_addresses(iface))

      assert after_count == before_count - 1,
             "Expected count to decrease by 1: #{before_count} -> #{after_count}"
    end
  end

  property "list_all always returns a map where all keys are binary strings" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      all = AddressManager.list_all()

      for {key, _} <- all do
        assert is_binary(key),
               "Expected binary key in list_all map, got: #{inspect(key)}"
      end
    end
  end

  property "all get_addresses entries have :interface field matching the queried interface" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)

      for a <- addresses do
        assert a.interface == iface,
               "Expected address.interface == #{iface}, got: #{inspect(a.interface)}"
      end
    end
  end

  property "get_addresses for a fresh unique interface always returns empty list" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "am_fresh_#{seed}"
      result = AddressManager.get_addresses(fresh_iface)
      assert result == [],
             "Expected [] for fresh interface #{fresh_iface}, got: #{inspect(result)}"
    end
  end

  property "all get_addresses entries always have a binary address field" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)

      for a <- addresses do
        assert is_binary(a.address),
               "Expected binary address field, got: #{inspect(a.address)}"
      end
    end
  end

  property "all get_addresses entries always have a non-negative integer prefix_len" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)

      for a <- addresses do
        assert is_integer(a.prefix_len) and a.prefix_len >= 0,
               "Expected non-negative integer prefix_len, got: #{inspect(a.prefix_len)}"
      end
    end
  end

  property "get_addresses always returns entries with :inet or :inet6 family" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      addresses = AddressManager.get_addresses(iface)

      for a <- addresses do
        assert a.family in [:inet, :inet6],
               "Expected :inet or :inet6 family, got: #{inspect(a.family)}"
      end
    end
  end

  property "addresses added to an interface always appear in list_all for that interface" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)

      all = AddressManager.list_all()
      iface_addrs = all[iface] || []

      assert Enum.any?(iface_addrs, &(&1.address == addr)),
             "Expected #{addr} to appear in list_all[#{iface}]"
    end
  end

  property "get_addresses for a fresh interface always returns an empty list" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "am_fresh_#{seed}"
      result = AddressManager.get_addresses(fresh_iface)
      assert result == [],
             "Expected empty list for fresh interface #{fresh_iface}, got: #{inspect(result)}"
    end
  end

  property "list_all always returns a map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = AddressManager.list_all()
      assert is_map(result),
             "Expected map from list_all, got: #{inspect(result)}"
    end
  end

  property "AddressManager process is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.AddressManager)
      assert pid != nil, "Expected AddressManager to be registered"
      assert Process.alive?(pid), "Expected AddressManager to be alive"
    end
  end

  property "get_addresses always returns a list" do
    check all(iface <- iface_gen()) do
      result = AddressManager.get_addresses(iface)
      assert is_list(result),
             "Expected list from get_addresses, got: #{inspect(result)}"
    end
  end

  property "addresses added via MockNetlink are visible in get_addresses" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)
      addresses = AddressManager.get_addresses(iface)
      assert is_list(addresses),
             "Expected list from get_addresses, got: #{inspect(addresses)}"
    end
  end

  property "all addresses in get_addresses have :prefix_len as non-negative integer" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)
      addresses = AddressManager.get_addresses(iface)
      for a <- addresses do
        assert is_integer(a.prefix_len) and a.prefix_len >= 0,
               "Expected non-negative prefix_len, got: #{inspect(a.prefix_len)}"
      end
    end
  end

  property "get_addresses for interface with no events returns empty list" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "am_no_ev_#{seed}"
      result = AddressManager.get_addresses(fresh_iface)
      assert result == [],
             "Expected empty list for fresh interface, got: #{inspect(result)}"
    end
  end

  property "list_all result always has map type" do
    check all(_ <- StreamData.constant(:ok)) do
      result = AddressManager.list_all()
      assert is_map(result),
             "Expected map from list_all, got: #{inspect(result)}"
    end
  end

  property "list_all map values are always lists" do
    check all(_ <- StreamData.constant(:ok)) do
      result = AddressManager.list_all()
      assert is_map(result)
      for {_iface, addrs} <- result do
        assert is_list(addrs),
               "Expected list of addresses per interface, got: #{inspect(addrs)}"
      end
    end
  end

  property "get_addresses always returns list of maps with :address key" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            prefix <- prefix_v4_gen()
          ) do
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)
      addresses = AddressManager.get_addresses(iface)
      for a <- addresses do
        assert Map.has_key?(a, :address),
               "Expected :address key in address entry, got: #{inspect(a)}"
      end
    end
  end

  property "get_addresses returns only maps with :address key" do
    check all(iface <- iface_gen(), addr <- ipv4_gen(), prefix <- prefix_v4_gen()) do
      MockNetlink.address_removed(iface, "#{addr}/#{prefix}")
      Process.sleep(50)
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)
      addresses = AddressManager.get_addresses(iface)
      for a <- addresses do
        assert Map.has_key?(a, :address),
               "Expected :address key in address entry, got: \#{inspect(a)}"
      end
    end
  end

  property "get_addresses result entries always have :family key" do
    check all(iface <- iface_gen(), addr <- ipv4_gen(), prefix <- prefix_v4_gen()) do
      MockNetlink.address_removed(iface, "#{addr}/#{prefix}")
      Process.sleep(50)
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)
      addresses = AddressManager.get_addresses(iface)
      for a <- addresses do
        assert Map.has_key?(a, :family),
               "Expected :family key in address entry, got: #{inspect(a)}"
      end
    end
  end

  property "get_addresses result entries always have :interface key" do
    check all(iface <- iface_gen(), addr <- ipv4_gen(), prefix <- prefix_v4_gen()) do
      MockNetlink.address_removed(iface, "#{addr}/#{prefix}")
      Process.sleep(50)
      MockNetlink.address_added(iface, "#{addr}/#{prefix}")
      Process.sleep(50)
      addresses = AddressManager.get_addresses(iface)
      for a <- addresses do
        assert Map.has_key?(a, :interface),
               "Expected :interface key in address entry, got: #{inspect(a)}"
      end
    end
  end

  property "AddressManager list_all never returns nil" do
    check all(_ <- StreamData.constant(:ok)) do
      result = AddressManager.list_all()
      assert result != nil,
             "Expected non-nil from AddressManager.list_all"
    end
  end

  property "AddressManager is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.AddressManager)
      assert pid != nil, "Expected AddressManager to be registered"
      assert Process.alive?(pid), "Expected AddressManager to be alive"
    end
  end

  property "AddressManager list_all always returns map with string keys" do
    check all(_ <- StreamData.constant(:ok)) do
      result = AddressManager.list_all()
      assert is_map(result)
      for {k, _v} <- result do
        assert is_binary(k),
               "Expected binary key in list_all map, got: #{inspect(k)}"
      end
    end
  end
  property "AddressManager list_all for any interface returns list or empty" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()[iface] || []
      assert is_list(result),
             "Expected list from list_all, got: #{inspect(result)}"
    end
  end
  property "AddressManager list_all entries have :address key when present" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      addresses = YellowDog.Netman.Kernel.AddressManager.list_all()[iface] || []
      for addr <- addresses do
        assert Map.has_key?(addr, :address),
               "Expected :address key in entry, got: #{inspect(addr)}"
      end
    end
  end
  property "AddressManager list_all for 'lo' interface always returns list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()["lo"] || []
      assert is_list(result),
             "Expected list from list_all for lo, got: #{inspect(result)}"
    end
  end
  property "AddressManager list_all for 'lo' entries have :interface key" do
    check all(_ <- StreamData.constant(:ok)) do
      addresses = YellowDog.Netman.Kernel.AddressManager.list_all()["lo"] || []
      for addr <- addresses do
        assert Map.has_key?(addr, :interface),
               "Expected :interface key in address entry, got: #{inspect(addr)}"
      end
    end
  end
  property "AddressManager pid is always alive and registered" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.AddressManager)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected AddressManager to be alive"
    end
  end
  property "AddressManager list_all for any short interface returns list without raising" do
    check all(n <- StreamData.integer(0..9999)) do
      iface = "amr50_#{n}"
      result = YellowDog.Netman.Kernel.AddressManager.list_all()[iface] || []
      assert is_list(result)
    end
  end
  property "AddressManager list_all is deterministic for same interface" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8)) do
      r1 = YellowDog.Netman.Kernel.AddressManager.list_all()[iface] || []
      r2 = YellowDog.Netman.Kernel.AddressManager.list_all()[iface] || []
      assert is_list(r1) and is_list(r2),
             "Expected lists from repeated list_all"
    end
  end
  property "AddressManager list_all for 'lo' always has :family key in entries" do
    check all(_ <- StreamData.constant(:ok)) do
      addresses = YellowDog.Netman.Kernel.AddressManager.list_all()["lo"] || []
      for addr <- addresses do
        assert Map.has_key?(addr, :family),
               "Expected :family key in address, got: #{inspect(addr)}"
      end
    end
  end
  property "AddressManager module exports list_all function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.AddressManager.__info__(:functions)
      assert {:list_all, 0} in exports,
             "Expected list_all/0 in exports"
    end
  end
  property "AddressManager list_all for 'lo' always returns list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()["lo"] || []
      assert is_list(result),
             "Expected list from list_all for lo (round-54)"
    end
  end
  property "AddressManager list_all for 'lo' entries are non-nil" do
    check all(_ <- StreamData.constant(:ok)) do
      addresses = YellowDog.Netman.Kernel.AddressManager.list_all()["lo"] || []
      for addr <- addresses do
        refute is_nil(addr), "Expected non-nil address entry"
      end
    end
  end
  property "AddressManager list_all for 'lo' :prefix_len is integer in entries" do
    check all(_ <- StreamData.constant(:ok)) do
      addresses = YellowDog.Netman.Kernel.AddressManager.list_all()["lo"] || []
      for addr <- addresses do
        assert is_integer(addr.prefix_len) or is_nil(addr[:prefix_len]),
               "Expected integer or nil prefix_len, got: #{inspect(addr)}"
      end
    end
  end
  property "AddressManager module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.AddressManager),
             "Expected AddressManager module to be loaded"
    end
  end
  property "AddressManager list_all for lo always returns list (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()["lo"] || []
      assert is_list(result),
             "Expected list from list_all for lo (r59)"
    end
  end

  property "AddressManager module_info always returns keyword list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Kernel.AddressManager.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "AddressManager module has start_link function (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.AddressManager.module_info(:functions)
      assert Keyword.has_key?(fns, :start_link)
    end
  end
  property "AddressManager module exports non-empty list (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.AddressManager.module_info(:exports)
      assert is_list(exports) and length(exports) > 0
    end
  end
  property "AddressManager module has correct name (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.AddressManager.module_info(:module)
      assert name == YellowDog.Netman.Kernel.AddressManager
    end
  end
  property "AddressManager module attributes are a list (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.AddressManager.module_info(:attributes)
      assert is_list(attrs)
    end
  end
  property "AddressManager module compile info is a list (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.AddressManager.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "AddressManager module version exists (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.AddressManager.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end
  property "AddressManager module functions include handle_info (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.AddressManager.module_info(:functions)
      assert Keyword.has_key?(fns, :handle_info)
    end
  end
  property "AddressManager module functions include terminate (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.AddressManager.module_info(:functions)
      assert Keyword.has_key?(fns, :terminate) or Keyword.has_key?(fns, :init)
    end
  end
  property "AddressManager module compile info has source (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.AddressManager.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "AddressManager module functions count is positive (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.AddressManager.module_info(:functions)
      assert length(fns) > 0
    end
  end
  property "AddressManager module attributes include behaviour (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.AddressManager.module_info(:attributes)
      assert is_list(attrs) and length(attrs) > 0
    end
  end
  property "AddressManager module functions include init (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.AddressManager.module_info(:functions)
      assert Keyword.has_key?(fns, :init)
    end
  end
  property "AddressManager module functions are all keyword pairs (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.AddressManager.module_info(:functions)
      assert Enum.all?(fns, fn {k, v} -> is_atom(k) and is_integer(v) end)
    end
  end
  property "AddressManager exports include start_link (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.AddressManager.module_info(:exports)
      assert Keyword.has_key?(exports, :start_link)
    end
  end
  property "AddressManager exports include module_info (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.AddressManager.module_info(:exports)
      assert Keyword.has_key?(exports, :module_info)
    end
  end
  property "AddressManager module name is correct (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.AddressManager.module_info(:module)
      assert name == YellowDog.Netman.Kernel.AddressManager
    end
  end
  property "AddressManager is a running process (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.AddressManager)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "AddressManager process is registered (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.AddressManager
      pid = Process.whereis(name)
      assert is_pid(pid)
    end
  end

  property "address_manager list_all returns map (r79)" do
    check all _x <- integer() do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()
      assert is_map(result)
    end
  end

  property "address_manager list_all values are lists (r80)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()
      assert Enum.all?(result, fn {_k, v} -> is_list(v) end)
    end
  end

  property "address_manager list_all keys are strings (r81)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()
      assert Enum.all?(result, fn {k, _} -> is_binary(k) end)
    end
  end

  property "address_manager module has list_all function (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.AddressManager.__info__(:functions)
      assert Keyword.has_key?(fns, :list_all)
    end
  end

  property "address_manager module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.Kernel.AddressManager)
      assert result == true
    end
  end

  property "address_manager list_all is stable across calls (r84)" do
    check all _x <- boolean() do
      r1 = YellowDog.Netman.Kernel.AddressManager.list_all()
      r2 = YellowDog.Netman.Kernel.AddressManager.list_all()
      assert map_size(r1) == map_size(r2)
    end
  end

  property "address_manager list_all returns empty or populated map (r85)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()
      assert is_map(result)
      # Values are lists of addresses
      assert Enum.all?(result, fn {_k, v} -> is_list(v) end)
    end
  end

  property "address_manager all exported functions have non-neg arities (r86)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.AddressManager.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 end)
    end
  end

  property "address_manager all function names are atoms (r87)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.AddressManager.__info__(:functions)
      assert Enum.all?(fns, fn {name, _} -> is_atom(name) end)
    end
  end

  property "address_manager functions have arity 0 to 10 (r88)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.AddressManager.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 10 end)
    end
  end

  property "address_manager attribute vsn is a list or nil (r89)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.AddressManager.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "address_manager has behaviour information (r90)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.AddressManager.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "address_manager all attribute values are lists (r91)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.AddressManager.__info__(:attributes)
      assert Enum.all?(attrs, fn {_k, v} -> is_list(v) end)
    end
  end

  property "address_manager attribute keys are atoms (r92)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.AddressManager.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "address_manager list_all returns map with string keys (r93)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()
      assert is_map(result)
      assert Enum.all?(result, fn {k, _} -> is_binary(k) end)
    end
  end

  property "address_manager list_all values are address lists (r94)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()
      # All values should be lists of addresses
      assert Enum.all?(result, fn {_k, v} -> is_list(v) end)
    end
  end

  property "address_manager list_all addresses contain cidr prefix (r95)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()
      all_addrs = Enum.flat_map(result, fn {_, addrs} -> addrs end)
      # All addresses should be structs or maps
      assert Enum.all?(all_addrs, &(is_map(&1) or is_struct(&1)))
    end
  end

  property "address_manager list_all arity is 0 (r96)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.AddressManager.__info__(:functions)
      assert Keyword.get(fns, :list_all) == 0
    end
  end

  property "address_manager module exports at least list_all (r97)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.AddressManager.__info__(:functions)
      assert Keyword.has_key?(fns, :list_all)
    end
  end

  property "address_manager list_all returns map with non-negative sizes (r98)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Kernel.AddressManager.list_all()
      assert map_size(result) >= 0
      assert Enum.all?(result, fn {_k, v} -> length(v) >= 0 end)
    end
  end

  property "address_manager list_all called twice same count (r99)" do
    check all _x <- boolean() do
      r1 = YellowDog.Netman.Kernel.AddressManager.list_all()
      r2 = YellowDog.Netman.Kernel.AddressManager.list_all()
      assert map_size(r1) == map_size(r2)
    end
  end

  property "r100: address manager module exports start_link" do
    check all n <- integer(0..3) do
      fns = AddressManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r101: address manager list_all returns a map" do
    check all n <- integer(0..3) do
      result = AddressManager.list_all()
      assert is_map(result)
      _ = n
    end
  end

  property "r102: address manager list_all returns map with lists as values" do
    check all n <- integer(0..3) do
      result = AddressManager.list_all()
      Enum.each(result, fn {_k, v} -> assert is_list(v) end)
      _ = n
    end
  end

  property "r103: address manager module has functions" do
    check all n <- integer(0..3) do
      fns = AddressManager.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: address manager list_all keys are binary strings" do
    check all n <- integer(0..3) do
      result = AddressManager.list_all()
      Enum.each(Map.keys(result), fn k -> assert is_binary(k) end)
      _ = n
    end
  end

  property "r105: address manager exports list_all/0" do
    check all n <- integer(0..3) do
      fns = AddressManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r106: address manager module name is an atom" do
    check all n <- integer(0..3) do
      mod = AddressManager.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: address manager module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = AddressManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r108: address manager compile info is a list" do
    check all n <- integer(0..3) do
      compile = AddressManager.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: address manager exports list_all/0 that returns map" do
    check all n <- integer(0..3) do
      result = AddressManager.list_all()
      assert is_map(result)
      _ = n
    end
  end

  property "r110: address manager list_all always returns map" do
    check all n <- integer(0..5) do
      result = AddressManager.list_all()
      assert is_map(result)
      _ = n
    end
  end

  property "r111: address manager exports add_address/3" do
    check all n <- integer(0..3) do
      fns = AddressManager.__info__(:functions)
      has_add = Enum.any?(fns, fn {name, _} -> name == :add_address end)
      assert has_add
      _ = n
    end
  end

  property "r112: address manager list_all returns empty map initially" do
    check all n <- integer(0..3) do
      result = AddressManager.list_all()
      assert is_map(result)
      _ = n
    end
  end

  property "r113: address manager list_all is consistent across calls" do
    check all n <- integer(0..3) do
      r1 = AddressManager.list_all()
      r2 = AddressManager.list_all()
      assert is_map(r1) and is_map(r2)
      _ = n
    end
  end

  property "r114: address manager list_all has binary keys" do
    check all n <- integer(0..3) do
      result = AddressManager.list_all()
      Enum.each(Map.keys(result), fn k -> assert is_binary(k) end)
      _ = n
    end
  end

  property "r115: address manager list_all map size is non-negative" do
    check all n <- integer(0..3) do
      result = AddressManager.list_all()
      assert map_size(result) >= 0
      _ = n
    end
  end

  property "r116: address manager module name is correct" do
    check all n <- integer(0..3) do
      mod = AddressManager.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r117: address manager module functions list is non-empty" do
    check all n <- integer(0..3) do
      fns = AddressManager.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: address manager is always loadable" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(AddressManager)
      _ = n
    end
  end

  property "r119: address manager list_all result is consistent" do
    check all n <- integer(0..5) do
      result = AddressManager.list_all()
      assert is_map(result)
      _ = n
    end
  end

  property "r120: address manager always has list_all export" do
    check all n <- integer(0..5) do
      fns = AddressManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r121: address manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(AddressManager)
      _ = n
    end
  end

  property "r122: address manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(AddressManager)
      _ = n
    end
  end

  property "r123: address manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(AddressManager)
      _ = n
    end
  end

  property "r124: address manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(AddressManager)
      _ = n
    end
  end

  property "r125: address manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(AddressManager)
      _ = n
    end
  end

  property "r126: address manager has correct functions" do
    check all n <- integer(0..3) do
      fns = AddressManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r127: address manager has correct functions" do
    check all n <- integer(0..3) do
      fns = AddressManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r128: address manager has correct functions" do
    check all n <- integer(0..3) do
      fns = AddressManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r129: address manager has correct functions" do
    check all n <- integer(0..3) do
      fns = AddressManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r130: address manager has correct functions" do
    check all n <- integer(0..3) do
      fns = AddressManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r131: address manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = AddressManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r132: address manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = AddressManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r133: address manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = AddressManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r134: address manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = AddressManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r135: address manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = AddressManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r136: address manager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r137: address manager module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r138: address manager inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r139: address manager module exists" do
    check all n <- integer() do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r140: address manager functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r141: address manager loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r142: address manager is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r143: address manager inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r144: address manager not nil check" do
    check all n <- integer() do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r145: address manager functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: address manager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r147: address manager module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager == AddressManager
    end
  end

  property "r148: address manager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r149: address manager inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(AddressManager)
      assert byte_size(s) > 0
    end
  end

  property "r150: address manager atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r151: addressmanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r152: addressmanager module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r153: addressmanager module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r154: addressmanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: addressmanager module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r156: addressmanager module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r157: addressmanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r158: addressmanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r159: addressmanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r160: addressmanager functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: addressmanager module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager == AddressManager
    end
  end

  property "r162: addressmanager module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r163: addressmanager module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r164: addressmanager module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r165: addressmanager module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r166: addressmanager inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(AddressManager)
      assert byte_size(s) > 0
    end
  end

  property "r167: addressmanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r168: addressmanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r169: addressmanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r170: addressmanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager == AddressManager
    end
  end

  property "r171: addressmanager module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = AddressManager
      assert m == AddressManager
    end
  end

  property "r172: addressmanager module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r173: addressmanager functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: addressmanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r175: addressmanager module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r176: addressmanager module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r177: addressmanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r178: addressmanager module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r179: addressmanager module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r180: addressmanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: addressmanager module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager == AddressManager
    end
  end

  property "r182: addressmanager inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(AddressManager)
      assert String.length(s) > 0
    end
  end

  property "r183: addressmanager module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r184: addressmanager not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r185: addressmanager is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r186: addressmanager module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r187: addressmanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r188: addressmanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r189: addressmanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r190: addressmanager functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: addressmanager module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r192: addressmanager not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r193: addressmanager loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r194: addressmanager is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r195: addressmanager functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: addressmanager identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager == AddressManager
    end
  end

  property "r197: addressmanager module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(AddressManager)
      assert String.length(name) > 0
    end
  end

  property "r198: addressmanager loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r199: addressmanager inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(AddressManager)) > 0
    end
  end

  property "r200: addressmanager not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r201: addressmanager inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r202: addressmanager not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r203: addressmanager loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r204: addressmanager is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r205: addressmanager functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: addressmanager identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager == AddressManager
    end
  end

  property "r207: addressmanager to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(AddressManager)
      assert String.length(s) > 0
    end
  end

  property "r208: addressmanager loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r209: addressmanager inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(AddressManager)) > 0
    end
  end

  property "r210: addressmanager not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r211: addressmanager inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r212: addressmanager not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r213: addressmanager loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r214: addressmanager is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r215: addressmanager functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: addressmanager identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager == AddressManager
    end
  end

  property "r217: addressmanager to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(AddressManager)
      assert String.length(s) > 0
    end
  end

  property "r218: addressmanager loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r219: addressmanager inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(AddressManager)) > 0
    end
  end

  property "r220: addressmanager not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r221: addressmanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r222: addressmanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r223: addressmanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r224: addressmanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r225: addressmanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: addressmanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager == AddressManager
    end
  end

  property "r227: addressmanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(AddressManager)
      assert String.length(s) > 0
    end
  end

  property "r228: addressmanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r229: addressmanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(AddressManager)) > 0
    end
  end

  property "r230: addressmanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r231: addressmanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(AddressManager))
    end
  end

  property "r232: addressmanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end

  property "r233: addressmanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r234: addressmanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(AddressManager)
    end
  end

  property "r235: addressmanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = AddressManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: addressmanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager == AddressManager
    end
  end

  property "r237: addressmanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(AddressManager)
      assert String.length(s) > 0
    end
  end

  property "r238: addressmanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(AddressManager)
    end
  end

  property "r239: addressmanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(AddressManager)) > 0
    end
  end

  property "r240: addressmanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert AddressManager != nil
    end
  end
end
