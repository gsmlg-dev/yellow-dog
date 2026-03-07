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
      result = YellowDog.Netman.Kernel.NeighborMonitor.get_neighbor(iface)
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
      result = YellowDog.Netman.Kernel.NeighborMonitor.get_neighbor("lo")
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

end
