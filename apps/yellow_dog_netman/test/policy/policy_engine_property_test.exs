defmodule YellowDog.Netman.PolicyEnginePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman.PolicyEngine

  defp connection_gen do
    gen all(
          id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          type <- StreamData.member_of([:ethernet, :wifi, :vpn, :cellular]),
          priority <- StreamData.integer(0..500)
        ) do
      %{id: "conn-#{id}", type: type, autoconnect_priority: priority, dns: [], interface: "eth0"}
    end
  end

  property "default_route always returns highest priority connection" do
    check all(connections <- StreamData.list_of(connection_gen(), min_length: 1, max_length: 10)) do
      case PolicyEngine.default_route(connections) do
        {:ok, id} ->
          # The returned connection should have the highest effective priority
          winner = Enum.find(connections, &((&1[:profile_id] || &1[:id]) == id))
          assert winner != nil

          max_priority = Enum.max_by(connections, &PolicyEngine.effective_priority/1)

          assert PolicyEngine.effective_priority(winner) ==
                   PolicyEngine.effective_priority(max_priority)

        :none ->
          assert connections == []
      end
    end
  end

  property "route_metrics are inversely proportional to priority" do
    check all(connections <- StreamData.list_of(connection_gen(), min_length: 2, max_length: 5)) do
      metrics = PolicyEngine.route_metrics(connections)

      # Higher priority connections should have lower metrics
      for conn <- connections do
        id = conn[:profile_id] || conn[:id]
        metric = Map.get(metrics, id, 0)
        assert metric >= 1
        assert metric <= 9999
      end
    end
  end

  property "effective_priority is deterministic" do
    check all(conn <- connection_gen()) do
      p1 = PolicyEngine.effective_priority(conn)
      p2 = PolicyEngine.effective_priority(conn)
      assert p1 == p2
    end
  end
end
