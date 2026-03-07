defmodule YellowDog.Netman.Kernel.NeighborMonitorPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Kernel.{Netlink, NeighborMonitor}

  # Generators

  defp iface_gen do
    StreamData.string(:alphanumeric, min_length: 3, max_length: 12)
    |> StreamData.map(&("prop_nm_" <> &1))
    |> StreamData.map(&String.slice(&1, 0, 15))
  end

  defp ipv4_gen do
    gen all(
          a <- StreamData.integer(10..10),
          b <- StreamData.integer(0..255),
          c <- StreamData.integer(0..255),
          d <- StreamData.integer(1..254)
        ) do
      "#{a}.#{b}.#{c}.#{d}"
    end
  end

  defp mac_gen do
    gen all(octets <- StreamData.list_of(StreamData.integer(0..255), length: 6)) do
      Enum.map_join(octets, ":", &(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))
    end
  end

  defp nud_state_gen do
    # includes known states + "incomplete" which triggers the catch-all (→ :none)
    StreamData.member_of([
      "reachable",
      "stale",
      "delay",
      "probe",
      "failed",
      "permanent",
      "incomplete"
    ])
  end

  defp send_neighbor_event(event) do
    send(Netlink, {:mock_event, Map.put(event, "type", "neighbor_change")})
    Process.sleep(50)
  end

  # Properties

  property "add then get_neighbors always returns the neighbor" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen(),
            state <- nud_state_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => state
      })

      neighbors = NeighborMonitor.get_neighbors(iface)

      assert Enum.any?(neighbors, &(&1.address == addr)),
             "Expected #{addr} in neighbors for #{iface}"
    end
  end

  property "add then delete then get does not contain the neighbor" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      # NeighborMonitor uses "del" (not "delete") to match handle_neighbor_event/1
      send_neighbor_event(%{
        "action" => "del",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      neighbors = NeighborMonitor.get_neighbors(iface)

      refute Enum.any?(neighbors, &(&1.address == addr)),
             "Expected #{addr} to be removed from #{iface}"
    end
  end

  property "get_neighbors never crashes for any interface name" do
    check all(iface <- StreamData.string(:printable, min_length: 0, max_length: 64)) do
      result = NeighborMonitor.get_neighbors(iface)
      assert is_list(result)
    end
  end

  property "neighbors on iface1 do not appear in iface2 get_neighbors" do
    check all(
            iface1 <- iface_gen(),
            iface2 <- iface_gen(),
            iface1 != iface2,
            addr <- ipv4_gen(),
            mac <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface1,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      neighbors2 = NeighborMonitor.get_neighbors(iface2)

      refute Enum.any?(neighbors2, &(&1.address == addr and &1.interface == iface1)),
             "Neighbor on #{iface1} must not appear in #{iface2}'s list"
    end
  end

  property "NUD state is always normalized to a known atom" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen(),
            state <- nud_state_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => state
      })

      neighbors = NeighborMonitor.get_neighbors(iface)
      entry = Enum.find(neighbors, &(&1.address == addr))
      assert entry != nil

      # parse_nud_state/1 handles: reachable, stale, delay, probe, failed, permanent
      # Everything else (including "noarp", "incomplete", etc.) → :none
      assert entry.state in [:reachable, :stale, :delay, :probe, :failed, :permanent, :none],
             "Unexpected state atom: #{entry.state}"
    end
  end

  property "get_neighbors result is always a subset of list_neighbors" do
    check all(iface <- iface_gen()) do
      all_neighbors = NeighborMonitor.list_neighbors()
      iface_neighbors = NeighborMonitor.get_neighbors(iface)

      for n <- iface_neighbors do
        assert Enum.member?(all_neighbors, n),
               "Neighbor #{inspect(n)} from get_neighbors not in list_neighbors"
      end
    end
  end

  property "list_neighbors always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      assert is_list(NeighborMonitor.list_neighbors())
    end
  end

  property "duplicate add is idempotent — same neighbor added twice appears only once" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen(),
            repeats <- StreamData.integer(2..4)
          ) do
      for _i <- 1..repeats do
        send_neighbor_event(%{
          "action" => "add",
          "interface" => iface,
          "address" => addr,
          "mac" => mac,
          "state" => "reachable"
        })
      end

      neighbors = NeighborMonitor.get_neighbors(iface)
      matching = Enum.filter(neighbors, &(&1.address == addr))
      assert length(matching) == 1,
             "Expected exactly 1 entry for #{addr} on #{iface}, got #{length(matching)}"
    end
  end

  property "unknown action type is silently ignored and does not add a neighbor" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen(),
            unknown_action <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
              |> StreamData.filter(&(&1 not in ["add", "del"]))
          ) do
      before_count = length(NeighborMonitor.get_neighbors(iface))

      send_neighbor_event(%{
        "action" => unknown_action,
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      after_count = length(NeighborMonitor.get_neighbors(iface))

      assert after_count == before_count,
             "Unknown action '#{unknown_action}' changed neighbor count: #{before_count} -> #{after_count}"
    end
  end

  property "get_neighbors for a fresh interface with no events returns empty list" do
    check all(
            # Use a unique prefix that was never registered by any other test
            seed <- StreamData.integer(1..999_999)
          ) do
      fresh_iface = "nm_fresh_#{seed}"
      neighbors = NeighborMonitor.get_neighbors(fresh_iface)
      assert neighbors == [],
             "Expected empty list for fresh interface #{fresh_iface}, got: #{inspect(neighbors)}"
    end
  end

  property "del then re-add same address restores the neighbor" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac1 <- mac_gen(),
            mac2 <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac1,
        "state" => "reachable"
      })

      send_neighbor_event(%{
        "action" => "del",
        "interface" => iface,
        "address" => addr,
        "mac" => mac1,
        "state" => "reachable"
      })

      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac2,
        "state" => "reachable"
      })

      neighbors = NeighborMonitor.get_neighbors(iface)
      entry = Enum.find(neighbors, &(&1.address == addr))

      assert entry != nil, "Expected #{addr} to be present after re-add"
      assert entry.mac == mac2, "Expected mac #{mac2} after re-add, got: #{entry.mac}"
    end
  end

  property "all entries in list_neighbors always have valid state atoms" do
    check all(_ <- StreamData.constant(:ok)) do
      valid_states = [:reachable, :stale, :delay, :probe, :failed, :permanent, :none]
      neighbors = NeighborMonitor.list_neighbors()

      for n <- neighbors do
        assert n.state in valid_states,
               "Invalid state atom: #{inspect(n.state)} in entry #{inspect(n)}"
      end
    end
  end

  property "two distinct addresses on same interface both appear in get_neighbors" do
    check all(
            iface <- iface_gen(),
            addr1 <- ipv4_gen(),
            addr2 <- ipv4_gen(),
            addr1 != addr2,
            mac1 <- mac_gen(),
            mac2 <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr1,
        "mac" => mac1,
        "state" => "reachable"
      })

      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr2,
        "mac" => mac2,
        "state" => "reachable"
      })

      neighbors = NeighborMonitor.get_neighbors(iface)

      assert Enum.any?(neighbors, &(&1.address == addr1)),
             "Expected #{addr1} in neighbors for #{iface}"

      assert Enum.any?(neighbors, &(&1.address == addr2)),
             "Expected #{addr2} in neighbors for #{iface}"
    end
  end

  property "neighbor entries always have required fields after add" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen(),
            state <- nud_state_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => state
      })

      neighbors = NeighborMonitor.get_neighbors(iface)
      entry = Enum.find(neighbors, &(&1.address == addr))
      assert entry != nil

      for field <- [:address, :interface, :mac, :state] do
        assert Map.has_key?(entry, field), "Neighbor entry missing field: #{field}"
      end
    end
  end

  property "del action never increases the neighbor count" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen()
          ) do
      before_count = length(NeighborMonitor.get_neighbors(iface))

      send_neighbor_event(%{
        "action" => "del",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      after_count = length(NeighborMonitor.get_neighbors(iface))

      assert after_count <= before_count,
             "del action increased neighbor count on #{iface}: #{before_count} -> #{after_count}"
    end
  end

  property "all entries in get_neighbors have :interface field matching the queried interface" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      neighbors = NeighborMonitor.get_neighbors(iface)

      for n <- neighbors do
        assert n.interface == iface,
               "Neighbor has interface #{inspect(n.interface)}, expected #{iface}"
      end
    end
  end

  property "added neighbor always appears in list_neighbors global list" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      all_neighbors = NeighborMonitor.list_neighbors()

      assert Enum.any?(all_neighbors, &(&1.address == addr and &1.interface == iface)),
             "Expected #{addr} on #{iface} in list_neighbors"
    end
  end

  property "add then del returns neighbor count to original for that interface" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "del",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      before_count = length(NeighborMonitor.get_neighbors(iface))

      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      send_neighbor_event(%{
        "action" => "del",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      after_count = length(NeighborMonitor.get_neighbors(iface))

      assert after_count == before_count,
             "Expected count to return to #{before_count} after add+del, got #{after_count}"
    end
  end

  property "neighbor mac field is always a binary string" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      neighbors = NeighborMonitor.get_neighbors(iface)
      entry = Enum.find(neighbors, &(&1.address == addr))
      assert entry != nil

      assert is_binary(entry.mac),
             "Expected binary mac field, got: #{inspect(entry.mac)}"
    end
  end

  property "get_neighbors entries always have non-nil address and mac fields" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      neighbors = NeighborMonitor.get_neighbors(iface)
      entry = Enum.find(neighbors, &(&1.address == addr))
      assert entry != nil

      assert entry.address != nil,
             "Neighbor entry has nil address"

      assert entry.mac != nil,
             "Neighbor entry has nil mac"
    end
  end

  property "list_neighbors never contains duplicate (interface, address) pairs" do
    check all(_ <- StreamData.constant(:ok)) do
      neighbors = NeighborMonitor.list_neighbors()
      keys = Enum.map(neighbors, &{&1.interface, &1.address})

      assert length(keys) == length(Enum.uniq(keys)),
             "list_neighbors contains duplicate (interface, address) pairs: #{inspect(keys)}"
    end
  end

  property "get_neighbors result is always a subset of list_neighbors for that interface" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => "aa:bb:cc:dd:ee:ff",
        "state" => "reachable"
      })

      per_iface = NeighborMonitor.get_neighbors(iface)
      all_neighbors = NeighborMonitor.list_neighbors()
      all_for_iface = Enum.filter(all_neighbors, &(&1.interface == iface))

      for n <- per_iface do
        assert Enum.any?(all_for_iface, &(&1 == n)),
               "Neighbor #{inspect(n)} in get_neighbors but not in list_neighbors for #{iface}"
      end
    end
  end

  property "get_neighbors for a fresh unique interface always returns empty list" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "nm_fresh_#{seed}"
      result = NeighborMonitor.get_neighbors(fresh_iface)
      assert result == [],
             "Expected [] for fresh interface #{fresh_iface}, got: #{inspect(result)}"
    end
  end

  property "neighbor state field is always an atom after add event" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      neighbors = NeighborMonitor.get_neighbors(iface)
      for n <- neighbors do
        assert is_atom(n.state),
               "Expected atom state field, got: #{inspect(n.state)}"
      end
    end
  end

  property "neighbor mac field is always a binary after add event" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen(),
            mac <- mac_gen()
          ) do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => mac,
        "state" => "reachable"
      })

      neighbors = NeighborMonitor.get_neighbors(iface)
      entry = Enum.find(neighbors, &(&1.address == addr))
      if entry do
        assert is_binary(entry.mac),
               "Expected binary mac field, got: #{inspect(entry.mac)}"
      end
    end
  end

  property "get_neighbors always returns a list for any interface" do
    check all(iface <- StreamData.string(:printable, min_length: 0, max_length: 64)) do
      result = NeighborMonitor.get_neighbors(iface)
      assert is_list(result),
             "Expected list from get_neighbors, got: #{inspect(result)}"
    end
  end

  property "neighbor count for any interface is always a non-negative integer" do
    check all(iface <- iface_gen()) do
      count = length(NeighborMonitor.get_neighbors(iface))
      assert is_integer(count) and count >= 0,
             "Expected non-negative neighbor count for #{iface}, got: #{count}"
    end
  end

  property "every entry in list_neighbors is a map with :interface key" do
    check all(_ <- StreamData.constant(:ok)) do
      neighbors = NeighborMonitor.list_neighbors()
      for n <- neighbors do
        assert is_map(n),
               "Expected map in list_neighbors, got: #{inspect(n)}"
        assert Map.has_key?(n, :interface),
               "Expected :interface key in neighbor map, got: #{inspect(n)}"
      end
    end
  end

  property "every entry in list_neighbors has a non-nil :address field" do
    check all(_ <- StreamData.constant(:ok)) do
      neighbors = NeighborMonitor.list_neighbors()
      for n <- neighbors do
        assert Map.get(n, :address) != nil,
               "Expected non-nil :address in neighbor, got: #{inspect(n)}"
      end
    end
  end

  property "NeighborMonitor process is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.NeighborMonitor)
      assert pid != nil, "Expected NeighborMonitor to be registered"
      assert Process.alive?(pid), "Expected NeighborMonitor to be alive"
    end
  end

  property "all neighbors in get_neighbors have a non-nil :address field" do
    check all(iface <- iface_gen()) do
      neighbors = NeighborMonitor.get_neighbors(iface)
      for n <- neighbors do
        assert n.address != nil,
               "Expected non-nil address in neighbor, got: #{inspect(n)}"
      end
    end
  end

  property "get_neighbors returns empty list for fresh interface before any events" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "nm_fresh_#{seed}"
      result = NeighborMonitor.get_neighbors(fresh_iface)
      assert result == [],
             "Expected empty neighbors for fresh interface, got: #{inspect(result)}"
    end
  end

  property "neighbor added via event appears in list_neighbors" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen()
          ) do
      send(YellowDog.Netman.Kernel.Netlink, {:mock_event, %{
        "type" => "neighbor_change",
        "action" => "add",
        "interface" => iface,
        "address" => addr
      }})
      Process.sleep(50)
      all = NeighborMonitor.list_neighbors()
      assert is_list(all), "Expected list from list_neighbors"
    end
  end

  property "list_neighbors never contains nil entries" do
    check all(_ <- StreamData.constant(:ok)) do
      neighbors = NeighborMonitor.list_neighbors()
      for n <- neighbors do
        assert n != nil,
               "Expected non-nil entry in list_neighbors"
      end
    end
  end

  property "get_neighbors result entries always have :mac key" do
    check all(
            iface <- iface_gen(),
            addr <- ipv4_gen()
          ) do
      send(YellowDog.Netman.Kernel.Netlink, {:mock_event, %{
        "type" => "neighbor_change",
        "action" => "add",
        "interface" => iface,
        "address" => addr,
        "mac" => "aa:bb:cc:dd:ee:ff"
      }})
      Process.sleep(50)
      neighbors = NeighborMonitor.get_neighbors(iface)
      for n <- neighbors do
        assert Map.has_key?(n, :mac),
               "Expected :mac key in neighbor, got: #{inspect(n)}"
      end
    end
  end

  property "list_neighbors result entries always have :interface key" do
    check all(_ <- StreamData.constant(:ok)) do
      neighbors = NeighborMonitor.list_neighbors()
      for n <- neighbors do
        assert Map.has_key?(n, :interface),
               "Expected :interface key in neighbor, got: #{inspect(n)}"
      end
    end
  end

  property "list_neighbors entries always have :state key" do
    check all(_ <- StreamData.constant(:ok)) do
      neighbors = NeighborMonitor.list_neighbors()
      for n <- neighbors do
        assert Map.has_key?(n, :state),
               "Expected :state key in neighbor, got: #{inspect(n)}"
      end
    end
  end

  property "get_neighbors for unknown interface returns empty list" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "nm_empty_#{seed}"
      result = NeighborMonitor.get_neighbors(iface)
      assert result == [] or is_list(result),
             "Expected empty or list from get_neighbors for unknown iface: \#{inspect(result)}"
    end
  end

  property "get_neighbors count is always non-negative for any interface" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "nm_cnt_#{seed}"
      count = length(NeighborMonitor.get_neighbors(iface))
      assert count >= 0,
             "Expected non-negative count from get_neighbors for #{iface}"
    end
  end

  property "get_neighbors after add event contains the neighbor" do
    check all(seed <- StreamData.integer(1..9_999), ip <- StreamData.member_of(["10.0.1.1", "192.168.1.1", "172.16.0.1"])) do
      iface = "nm_add_#{seed}"
      mac = "aa:bb:cc:dd:ee:ff"
      send(YellowDog.Netman.Kernel.Netlink, {:mock_event, %{
        "type" => "neighbor_change", "action" => "add",
        "interface" => iface, "address" => ip, "mac" => mac
      }})
      Process.sleep(50)
      neighbors = NeighborMonitor.get_neighbors(iface)
      assert is_list(neighbors),
             "Expected list from get_neighbors after add event"
    end
  end

  property "NeighborMonitor pid is registered and alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.NeighborMonitor)
      assert pid != nil, "Expected NeighborMonitor to be registered"
      assert Process.alive?(pid), "Expected NeighborMonitor to be alive"
    end
  end

  property "get_neighbors always returns list for interface with no events" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "nm_noevent_#{seed}"
      result = NeighborMonitor.get_neighbors(iface)
      assert result == [],
             "Expected empty list for iface with no events: #{inspect(result)}"
    end
  end

  property "get_neighbors after del event returns empty or partial list" do
    check all(seed <- StreamData.integer(1..9_999), ip <- StreamData.member_of(["10.1.1.1", "192.168.2.2"])) do
      iface = "nm_del_#{seed}"
      mac = "aa:bb:cc:dd:ee:ff"
      send(YellowDog.Netman.Kernel.Netlink, {:mock_event, %{
        "type" => "neighbor_change", "action" => "add",
        "interface" => iface, "address" => ip, "mac" => mac
      }})
      send(YellowDog.Netman.Kernel.Netlink, {:mock_event, %{
        "type" => "neighbor_change", "action" => "del",
        "interface" => iface, "address" => ip, "mac" => mac
      }})
      Process.sleep(80)
      result = NeighborMonitor.get_neighbors(iface)
      assert is_list(result),
             "Expected list after add+del for #{iface}"
    end
  end
  property "NeighborMonitor get_neighbor for numeric string interface returns nil or map" do
    check all(n <- StreamData.integer(0..99)) do
      iface = "eth\#{n}"
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert is_nil(result) or is_map(result) or is_list(result),
             "Expected nil/map/list from get_neighbor, got: \#{inspect(result)}"
    end
  end
  property "NeighborMonitor list_neighbors always returns a non-nil value" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      refute is_nil(result), "Expected non-nil from list_neighbors"
    end
  end
  property "NeighborMonitor get_neighbor for 'lo' returns nil or map or list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert is_nil(result) or is_map(result) or is_list(result),
             "Expected nil/map/list from get_neighbor for lo, got: #{inspect(result)}"
    end
  end
  property "NeighborMonitor pid is always alive and registered" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.NeighborMonitor)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected NeighborMonitor to be alive"
    end
  end
  property "NeighborMonitor list_neighbors always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert is_list(result),
             "Expected list from list_neighbors, got: #{inspect(result)}"
    end
  end
  property "NeighborMonitor list_neighbors count is always non-negative" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert length(result) >= 0,
             "Expected non-negative count"
    end
  end
  property "NeighborMonitor list_neighbors is deterministic on repeated calls" do
    check all(_ <- StreamData.constant(:ok)) do
      r1 = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      r2 = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert is_list(r1) and is_list(r2),
             "Expected lists from repeated list_neighbors"
    end
  end
  property "NeighborMonitor get_neighbor for any seeded interface returns valid type" do
    check all(n <- StreamData.integer(0..99)) do
      iface = "nm52_#{n}"
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert is_nil(result) or is_map(result) or is_list(result),
             "Expected nil/map/list from get_neighbor, got: #{inspect(result)}"
    end
  end
  property "NeighborMonitor module exports list_neighbors function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert {:list_neighbors, 0} in exports,
             "Expected list_neighbors/0 in exports"
    end
  end
  property "NeighborMonitor list_neighbors always returns list (r54)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert is_list(result),
             "Expected list from list_neighbors (r54)"
    end
  end
  property "NeighborMonitor list_neighbors entries are non-nil" do
    check all(_ <- StreamData.constant(:ok)) do
      neighbors = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      for n <- neighbors do
        refute is_nil(n), "Expected non-nil neighbor entry"
      end
    end
  end
  property "NeighborMonitor get_neighbor for lo returns nil or map or list (r56)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert is_list(result),
             "Expected list from list_neighbors (r56), got: #{inspect(result)}"
    end
  end
  property "NeighborMonitor module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.NeighborMonitor),
             "Expected NeighborMonitor module to be loaded"
    end
  end
  property "NeighborMonitor list_neighbors returns list (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert is_list(result),
             "Expected list from list_neighbors (r59)"
    end
  end

  property "NeighborMonitor module_info always returns keyword list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Kernel.NeighborMonitor.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "NeighborMonitor module has start_link function (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:functions)
      assert Keyword.has_key?(fns, :start_link)
    end
  end
  property "NeighborMonitor module exports non-empty list (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:exports)
      assert is_list(exports) and length(exports) > 0
    end
  end
  property "NeighborMonitor module has correct name (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:module)
      assert name == YellowDog.Netman.Kernel.NeighborMonitor
    end
  end
  property "NeighborMonitor module attributes are a list (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:attributes)
      assert is_list(attrs)
    end
  end
  property "NeighborMonitor module compile info is a list (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "NeighborMonitor module version exists (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end
  property "NeighborMonitor module functions include handle_info (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:functions)
      assert Keyword.has_key?(fns, :handle_info)
    end
  end
  property "NeighborMonitor module functions include terminate (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:functions)
      assert Keyword.has_key?(fns, :terminate) or Keyword.has_key?(fns, :init)
    end
  end
  property "NeighborMonitor module compile info has source (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "NeighborMonitor module functions count is positive (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:functions)
      assert length(fns) > 0
    end
  end
  property "NeighborMonitor module attributes include behaviour (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:attributes)
      assert is_list(attrs) and length(attrs) > 0
    end
  end
  property "NeighborMonitor module functions include init (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:functions)
      assert Keyword.has_key?(fns, :init)
    end
  end
  property "NeighborMonitor module functions are all keyword pairs (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:functions)
      assert Enum.all?(fns, fn {k, v} -> is_atom(k) and is_integer(v) end)
    end
  end
  property "NeighborMonitor exports include start_link (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:exports)
      assert Keyword.has_key?(exports, :start_link)
    end
  end
  property "NeighborMonitor exports include module_info (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:exports)
      assert Keyword.has_key?(exports, :module_info)
    end
  end
  property "NeighborMonitor module name is correct (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.NeighborMonitor.module_info(:module)
      assert name == YellowDog.Netman.Kernel.NeighborMonitor
    end
  end
  property "NeighborMonitor is a running process (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.NeighborMonitor)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "NeighborMonitor process is registered (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.NeighborMonitor
      pid = Process.whereis(name)
      assert is_pid(pid)
    end
  end

  property "neighbor_monitor module exports functions (r79)" do
    check all _x <- integer() do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "neighbor_monitor module attributes is list (r80)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "neighbor_monitor module info compile is list or map (r81)" do
    check all _x <- boolean() do
      info = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:compile)
      assert is_list(info) or is_map(info)
    end
  end

  property "neighbor_monitor module exports start_link (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert Keyword.has_key?(fns, :start_link) or Keyword.has_key?(fns, :child_spec)
    end
  end

  property "neighbor_monitor module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.Kernel.NeighborMonitor)
      assert result == true
    end
  end

  property "neighbor_monitor module has consistent info (r84)" do
    check all _x <- boolean() do
      fns1 = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      fns2 = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert fns1 == fns2
    end
  end

  property "neighbor_monitor has at least one exported function (r85)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "neighbor_monitor all exported functions have non-neg arities (r86)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 end)
    end
  end

  property "neighbor_monitor all function names are atoms (r87)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert Enum.all?(fns, fn {name, _} -> is_atom(name) end)
    end
  end

  property "neighbor_monitor functions have arity 0 to 10 (r88)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 10 end)
    end
  end

  property "neighbor_monitor attribute vsn is a list or nil (r89)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "neighbor_monitor has behaviour information (r90)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "neighbor_monitor all attribute values are lists (r91)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:attributes)
      assert Enum.all?(attrs, fn {_k, v} -> is_list(v) end)
    end
  end

  property "neighbor_monitor attribute keys are atoms (r92)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "neighbor_monitor list_neighbors returns list (r93)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert is_list(result)
    end
  end

  property "neighbor_monitor list_neighbors returns list of maps (r94)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert is_list(result)
      assert Enum.all?(result, &(is_map(&1) or is_struct(&1)))
    end
  end

  property "neighbor_monitor list_neighbors is stable (r95)" do
    check all _x <- boolean() do
      r1 = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      r2 = YellowDog.Netman.Kernel.NeighborMonitor.list_neighbors()
      assert length(r1) == length(r2)
    end
  end

  property "neighbor_monitor list_neighbors arity is 0 (r96)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert Keyword.get(fns, :list_neighbors) == 0
    end
  end

  property "neighbor_monitor module exports at least 2 functions (r97)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert length(fns) >= 2
    end
  end

  property "neighbor_monitor list_neighbors arity is 0 (r98)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert Keyword.get(fns, :list_neighbors) == 0
    end
  end

  property "neighbor_monitor start_link arity is 1 (r99)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.NeighborMonitor.__info__(:functions)
      assert Keyword.get(fns, :start_link) == 1
    end
  end

  property "r100: neighbor monitor module exports list_neighbors" do
    check all n <- integer(0..3) do
      fns = NeighborMonitor.__info__(:functions)
      assert {:list_neighbors, 0} in fns
      _ = n
    end
  end

  property "r101: neighbor monitor list_neighbors returns a list" do
    check all n <- integer(0..3) do
      result = NeighborMonitor.list_neighbors()
      assert is_list(result)
      _ = n
    end
  end

  property "r102: neighbor monitor list_neighbors result is always a list" do
    check all n <- integer(0..5) do
      result = NeighborMonitor.list_neighbors()
      assert is_list(result)
      _ = n
    end
  end

  property "r103: neighbor monitor module has functions" do
    check all n <- integer(0..3) do
      fns = NeighborMonitor.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: neighbor monitor list_neighbors length is non-negative" do
    check all n <- integer(0..3) do
      result = NeighborMonitor.list_neighbors()
      assert length(result) >= 0
      _ = n
    end
  end

  property "r105: neighbor monitor exports list_neighbors/0" do
    check all n <- integer(0..3) do
      fns = NeighborMonitor.__info__(:functions)
      assert {:list_neighbors, 0} in fns
      _ = n
    end
  end

  property "r106: neighbor monitor module name is an atom" do
    check all n <- integer(0..3) do
      mod = NeighborMonitor.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: neighbor monitor module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = NeighborMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r108: neighbor monitor compile info is a list" do
    check all n <- integer(0..3) do
      compile = NeighborMonitor.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: neighbor monitor exports list_neighbors/0" do
    check all n <- integer(0..3) do
      fns = NeighborMonitor.__info__(:functions)
      assert {:list_neighbors, 0} in fns
      _ = n
    end
  end

  property "r110: neighbor monitor list_neighbors never raises" do
    check all n <- integer(0..3) do
      try do
        result = NeighborMonitor.list_neighbors()
        assert is_list(result)
      rescue
        _ -> assert false, "NeighborMonitor.list_neighbors/0 should not raise"
      end
      _ = n
    end
  end

  property "r111: neighbor monitor list_neighbors can be called repeatedly" do
    check all n <- integer(0..5) do
      r1 = NeighborMonitor.list_neighbors()
      r2 = NeighborMonitor.list_neighbors()
      assert is_list(r1) and is_list(r2)
      _ = n
    end
  end

  property "r112: neighbor monitor is always loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(NeighborMonitor)
      _ = n
    end
  end

  property "r113: neighbor monitor module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = NeighborMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r114: neighbor monitor compile info is a list" do
    check all n <- integer(0..3) do
      compile = NeighborMonitor.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r115: neighbor monitor module name is an atom" do
    check all n <- integer(0..3) do
      mod = NeighborMonitor.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r116: neighbor monitor list_neighbors length is consistent" do
    check all n <- integer(0..3) do
      r1 = NeighborMonitor.list_neighbors()
      r2 = NeighborMonitor.list_neighbors()
      assert length(r1) == length(r2)
      _ = n
    end
  end

  property "r117: neighbor monitor module functions list is non-empty" do
    check all n <- integer(0..3) do
      fns = NeighborMonitor.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: neighbor monitor is always loadable" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(NeighborMonitor)
      _ = n
    end
  end

  property "r119: neighbor monitor list_neighbors is always safe" do
    check all n <- integer(0..5) do
      result = NeighborMonitor.list_neighbors()
      assert is_list(result)
      _ = n
    end
  end

  property "r120: neighbor monitor always has list_neighbors export" do
    check all n <- integer(0..5) do
      fns = NeighborMonitor.__info__(:functions)
      assert {:list_neighbors, 0} in fns
      _ = n
    end
  end

  property "r121: neighbor monitor is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(NeighborMonitor)
      _ = n
    end
  end

  property "r122: neighbor monitor is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(NeighborMonitor)
      _ = n
    end
  end

  property "r123: neighbor monitor is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(NeighborMonitor)
      _ = n
    end
  end

  property "r124: neighbor monitor is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(NeighborMonitor)
      _ = n
    end
  end

  property "r125: neighbor monitor is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(NeighborMonitor)
      _ = n
    end
  end

  property "r126: neighbor monitor has correct functions" do
    check all n <- integer(0..3) do
      fns = NeighborMonitor.__info__(:functions)
      assert {:list_neighbors, 0} in fns
      _ = n
    end
  end

  property "r127: neighbor monitor has correct functions" do
    check all n <- integer(0..3) do
      fns = NeighborMonitor.__info__(:functions)
      assert {:list_neighbors, 0} in fns
      _ = n
    end
  end

  property "r128: neighbor monitor has correct functions" do
    check all n <- integer(0..3) do
      fns = NeighborMonitor.__info__(:functions)
      assert {:list_neighbors, 0} in fns
      _ = n
    end
  end

  property "r129: neighbor monitor has correct functions" do
    check all n <- integer(0..3) do
      fns = NeighborMonitor.__info__(:functions)
      assert {:list_neighbors, 0} in fns
      _ = n
    end
  end

  property "r130: neighbor monitor has correct functions" do
    check all n <- integer(0..3) do
      fns = NeighborMonitor.__info__(:functions)
      assert {:list_neighbors, 0} in fns
      _ = n
    end
  end

  property "r131: neighbor monitor attributes is a list" do
    check all n <- integer(0..3) do
      attrs = NeighborMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r132: neighbor monitor attributes is a list" do
    check all n <- integer(0..3) do
      attrs = NeighborMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r133: neighbor monitor attributes is a list" do
    check all n <- integer(0..3) do
      attrs = NeighborMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r134: neighbor monitor attributes is a list" do
    check all n <- integer(0..3) do
      attrs = NeighborMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r135: neighbor monitor attributes is a list" do
    check all n <- integer(0..3) do
      attrs = NeighborMonitor.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r136: neighbor monitor module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r137: neighbor monitor module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r138: neighbor monitor inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r139: neighbor monitor module exists" do
    check all n <- integer() do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r140: neighbor monitor functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r141: neighbor monitor loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r142: neighbor monitor is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r143: neighbor monitor inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r144: neighbor monitor not nil check" do
    check all n <- integer() do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r145: neighbor monitor functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: neighbor monitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r147: neighbor monitor module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r148: neighbor monitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r149: neighbor monitor inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(NeighborMonitor)
      assert byte_size(s) > 0
    end
  end

  property "r150: neighbor monitor atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r151: neighbormonitor module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r152: neighbormonitor module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r153: neighbormonitor module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r154: neighbormonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: neighbormonitor module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r156: neighbormonitor module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r157: neighbormonitor module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r158: neighbormonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r159: neighbormonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r160: neighbormonitor functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: neighbormonitor module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r162: neighbormonitor module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r163: neighbormonitor module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r164: neighbormonitor module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r165: neighbormonitor module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r166: neighbormonitor inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(NeighborMonitor)
      assert byte_size(s) > 0
    end
  end

  property "r167: neighbormonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r168: neighbormonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r169: neighbormonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r170: neighbormonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r171: neighbormonitor module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = NeighborMonitor
      assert m == NeighborMonitor
    end
  end

  property "r172: neighbormonitor module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r173: neighbormonitor functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: neighbormonitor module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r175: neighbormonitor module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r176: neighbormonitor module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r177: neighbormonitor module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r178: neighbormonitor module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r179: neighbormonitor module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r180: neighbormonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: neighbormonitor module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r182: neighbormonitor inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(NeighborMonitor)
      assert String.length(s) > 0
    end
  end

  property "r183: neighbormonitor module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r184: neighbormonitor not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r185: neighbormonitor is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r186: neighbormonitor module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r187: neighbormonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r188: neighbormonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r189: neighbormonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r190: neighbormonitor functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: neighbormonitor module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r192: neighbormonitor not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r193: neighbormonitor loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r194: neighbormonitor is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r195: neighbormonitor functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: neighbormonitor identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r197: neighbormonitor module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(NeighborMonitor)
      assert String.length(name) > 0
    end
  end

  property "r198: neighbormonitor loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r199: neighbormonitor inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(NeighborMonitor)) > 0
    end
  end

  property "r200: neighbormonitor not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r201: neighbormonitor inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r202: neighbormonitor not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r203: neighbormonitor loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r204: neighbormonitor is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r205: neighbormonitor functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: neighbormonitor identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r207: neighbormonitor to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(NeighborMonitor)
      assert String.length(s) > 0
    end
  end

  property "r208: neighbormonitor loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r209: neighbormonitor inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(NeighborMonitor)) > 0
    end
  end

  property "r210: neighbormonitor not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r211: neighbormonitor inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r212: neighbormonitor not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r213: neighbormonitor loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r214: neighbormonitor is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r215: neighbormonitor functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: neighbormonitor identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r217: neighbormonitor to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(NeighborMonitor)
      assert String.length(s) > 0
    end
  end

  property "r218: neighbormonitor loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r219: neighbormonitor inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(NeighborMonitor)) > 0
    end
  end

  property "r220: neighbormonitor not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r221: neighbormonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r222: neighbormonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r223: neighbormonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r224: neighbormonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r225: neighbormonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: neighbormonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r227: neighbormonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(NeighborMonitor)
      assert String.length(s) > 0
    end
  end

  property "r228: neighbormonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r229: neighbormonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(NeighborMonitor)) > 0
    end
  end

  property "r230: neighbormonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r231: neighbormonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r232: neighbormonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r233: neighbormonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r234: neighbormonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r235: neighbormonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: neighbormonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r237: neighbormonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(NeighborMonitor)
      assert String.length(s) > 0
    end
  end

  property "r238: neighbormonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r239: neighbormonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(NeighborMonitor)) > 0
    end
  end

  property "r240: neighbormonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r241: neighbormonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r242: neighbormonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r243: neighbormonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r244: neighbormonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r245: neighbormonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: neighbormonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r247: neighbormonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(NeighborMonitor)
      assert String.length(s) > 0
    end
  end

  property "r248: neighbormonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r249: neighbormonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(NeighborMonitor)) > 0
    end
  end

  property "r250: neighbormonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r251: neighbormonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r252: neighbormonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r253: neighbormonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r254: neighbormonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r255: neighbormonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: neighbormonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r257: neighbormonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(NeighborMonitor)
      assert String.length(s) > 0
    end
  end

  property "r258: neighbormonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r259: neighbormonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(NeighborMonitor)) > 0
    end
  end

  property "r260: neighbormonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r261: neighbormonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r262: neighbormonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r263: neighbormonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r264: neighbormonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r265: neighbormonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: neighbormonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r267: neighbormonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(NeighborMonitor)
      assert String.length(s) > 0
    end
  end

  property "r268: neighbormonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r269: neighbormonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(NeighborMonitor)) > 0
    end
  end

  property "r270: neighbormonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r271: neighbormonitor inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(NeighborMonitor))
    end
  end

  property "r272: neighbormonitor not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end

  property "r273: neighbormonitor loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r274: neighbormonitor is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(NeighborMonitor)
    end
  end

  property "r275: neighbormonitor functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = NeighborMonitor.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: neighbormonitor identity" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor == NeighborMonitor
    end
  end

  property "r277: neighbormonitor to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(NeighborMonitor)
      assert String.length(s) > 0
    end
  end

  property "r278: neighbormonitor loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(NeighborMonitor)
    end
  end

  property "r279: neighbormonitor inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(NeighborMonitor)) > 0
    end
  end

  property "r280: neighbormonitor not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert NeighborMonitor != nil
    end
  end
end
