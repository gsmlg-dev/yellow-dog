defmodule YellowDog.Netman.Kernel.NeighborMonitorTest do
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.{Netlink, NeighborMonitor}

  defp send_neighbor_event(event) do
    send(Netlink, {:mock_event, Map.put(event, "type", "neighbor_change")})
    Process.sleep(50)
  end

  test "list_neighbors returns a list" do
    assert is_list(NeighborMonitor.list_neighbors())
  end

  test "adding a neighbor makes it visible" do
    send_neighbor_event(%{
      "action" => "add",
      "interface" => "neigh_test_eth0",
      "address" => "10.99.0.1",
      "mac" => "aa:bb:cc:dd:ee:01",
      "state" => "reachable"
    })

    neighbors = NeighborMonitor.get_neighbors("neigh_test_eth0")
    assert length(neighbors) >= 1
    neigh = Enum.find(neighbors, &(&1.address == "10.99.0.1"))
    assert neigh != nil
    assert neigh.mac == "aa:bb:cc:dd:ee:01"
    assert neigh.state == :reachable
  end

  test "deleting a neighbor removes it" do
    send_neighbor_event(%{
      "action" => "add",
      "interface" => "neigh_test_eth1",
      "address" => "10.99.0.2",
      "mac" => "aa:bb:cc:dd:ee:02",
      "state" => "stale"
    })

    assert Enum.any?(
             NeighborMonitor.get_neighbors("neigh_test_eth1"),
             &(&1.address == "10.99.0.2")
           )

    send_neighbor_event(%{
      "action" => "del",
      "interface" => "neigh_test_eth1",
      "address" => "10.99.0.2"
    })

    refute Enum.any?(
             NeighborMonitor.get_neighbors("neigh_test_eth1"),
             &(&1.address == "10.99.0.2")
           )
  end

  test "get_neighbors filters by interface" do
    send_neighbor_event(%{
      "action" => "add",
      "interface" => "neigh_filter_a",
      "address" => "10.100.0.1",
      "mac" => "11:22:33:44:55:66",
      "state" => "permanent"
    })

    send_neighbor_event(%{
      "action" => "add",
      "interface" => "neigh_filter_b",
      "address" => "10.100.0.2",
      "mac" => "66:55:44:33:22:11",
      "state" => "delay"
    })

    a_neighbors = NeighborMonitor.get_neighbors("neigh_filter_a")
    b_neighbors = NeighborMonitor.get_neighbors("neigh_filter_b")

    assert Enum.any?(a_neighbors, &(&1.address == "10.100.0.1"))
    refute Enum.any?(a_neighbors, &(&1.address == "10.100.0.2"))
    assert Enum.any?(b_neighbors, &(&1.address == "10.100.0.2"))
  end

  test "NUD state parsing" do
    states = [
      {"reachable", :reachable},
      {"stale", :stale},
      {"delay", :delay},
      {"probe", :probe},
      {"failed", :failed},
      {"permanent", :permanent},
      {"unknown", :none}
    ]

    for {state_str, expected_atom} <- states do
      send_neighbor_event(%{
        "action" => "add",
        "interface" => "nud_test_#{state_str}",
        "address" => "10.200.0.#{:erlang.phash2(state_str, 254) + 1}",
        "state" => state_str
      })

      neighbors = NeighborMonitor.get_neighbors("nud_test_#{state_str}")
      assert Enum.any?(neighbors, &(&1.state == expected_atom)),
             "Expected #{expected_atom} for state string #{inspect(state_str)}"
    end
  end
end
