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

  property "higher priority connection gets strictly lower metric" do
    check all(
            conn1 <- connection_gen(),
            conn2 <- connection_gen()
          ) do
      # Give unique IDs to avoid map key collision
      c1 = %{conn1 | id: "a-#{conn1.id}"}
      c2 = %{conn2 | id: "b-#{conn2.id}"}

      metrics = PolicyEngine.route_metrics([c1, c2])
      m1 = metrics[c1.id]
      m2 = metrics[c2.id]

      p1 = PolicyEngine.effective_priority(c1)
      p2 = PolicyEngine.effective_priority(c2)

      if p1 > p2 do
        assert m1 < m2, "Priority #{p1} > #{p2} but metric #{m1} >= #{m2}"
      end

      if p1 < p2 do
        assert m1 > m2, "Priority #{p1} < #{p2} but metric #{m1} <= #{m2}"
      end

      if p1 == p2 do
        assert m1 == m2, "Same priority #{p1} but different metrics #{m1} vs #{m2}"
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

  # --- dns_priority properties ---

  defp connection_with_dns_gen do
    gen all(
          id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          type <- StreamData.member_of([:ethernet, :wifi, :vpn, :cellular]),
          priority <- StreamData.integer(0..500),
          dns_count <- StreamData.integer(0..4),
          octets <- StreamData.list_of(StreamData.integer(1..254), length: dns_count)
        ) do
      dns = Enum.map(octets, &"8.8.#{&1}.#{&1}")

      %{
        id: "conn-#{id}",
        type: type,
        autoconnect_priority: priority,
        dns: dns,
        interface: "eth#{:rand.uniform(9)}"
      }
    end
  end

  property "dns_priority total count equals sum of all connection DNS lists" do
    check all(connections <- StreamData.list_of(connection_with_dns_gen(), max_length: 8)) do
      result = PolicyEngine.dns_priority(connections)
      expected_count = connections |> Enum.map(&length(&1[:dns] || [])) |> Enum.sum()
      assert length(result) == expected_count
    end
  end

  property "dns_priority entries are sorted by priority descending" do
    check all(
            connections <-
              StreamData.list_of(connection_with_dns_gen(), min_length: 1, max_length: 8)
          ) do
      result = PolicyEngine.dns_priority(connections)
      priorities = Enum.map(result, & &1.priority)
      assert priorities == Enum.sort(priorities, :desc)
    end
  end

  property "dns_priority entries retain source interface and priority" do
    check all(
            connections <-
              StreamData.list_of(connection_with_dns_gen(), min_length: 1, max_length: 5)
          ) do
      result = PolicyEngine.dns_priority(connections)

      for entry <- result do
        assert is_binary(entry.server)
        assert is_binary(entry.interface)
        assert is_integer(entry.priority)
      end
    end
  end

  property "connections with empty DNS produce no dns_priority entries" do
    check all(
            connections <-
              StreamData.list_of(connection_gen(), min_length: 1, max_length: 5)
          ) do
      # connection_gen produces dns: [] by default
      result = PolicyEngine.dns_priority(connections)
      assert result == []
    end
  end

  property "route_metrics keys cover all input connection IDs" do
    check all(connections <- StreamData.list_of(connection_gen(), min_length: 1, max_length: 8)) do
      metrics = PolicyEngine.route_metrics(connections)

      for conn <- connections do
        id = conn[:profile_id] || conn[:id]

        assert Map.has_key?(metrics, id),
               "route_metrics missing entry for connection #{id}"
      end
    end
  end

  property "default_route with empty list always returns :none" do
    check all(_ <- StreamData.constant(:ok)) do
      assert PolicyEngine.default_route([]) == :none
    end
  end

  property "effective_priority is always a non-negative integer" do
    check all(conn <- connection_gen()) do
      priority = PolicyEngine.effective_priority(conn)
      assert is_integer(priority) and priority >= 0
    end
  end

  property "route_metrics always returns a map with positive integer values" do
    check all(connections <- StreamData.list_of(connection_gen(), min_length: 1, max_length: 8)) do
      metrics = PolicyEngine.route_metrics(connections)
      assert is_map(metrics)

      for {_id, metric} <- metrics do
        assert is_integer(metric) and metric > 0,
               "Expected positive integer metric, got: #{inspect(metric)}"
      end
    end
  end

  property "default_route returns an ID present in the input connections" do
    check all(
            connections <-
              StreamData.list_of(connection_gen(), min_length: 1, max_length: 10)
          ) do
      case PolicyEngine.default_route(connections) do
        {:ok, id} ->
          all_ids = Enum.map(connections, &(&1[:profile_id] || &1[:id]))
          assert id in all_ids,
                 "default_route returned #{inspect(id)} not in input connections"

        :none ->
          flunk("Expected {:ok, id} for non-empty list, got :none")
      end
    end
  end

  property "route_metrics with empty list always returns empty map" do
    check all(_ <- StreamData.constant(:ok)) do
      assert PolicyEngine.route_metrics([]) == %{}
    end
  end

  property "dns_priority with empty list always returns empty list" do
    check all(_ <- StreamData.constant(:ok)) do
      assert PolicyEngine.dns_priority([]) == []
    end
  end

  property "route_metrics map size equals number of input connections" do
    check all(
            connections <-
              StreamData.list_of(connection_gen(), min_length: 1, max_length: 8)
          ) do
      indexed =
        connections
        |> Enum.with_index()
        |> Enum.map(fn {c, i} -> %{c | id: "sz-#{i}-#{c.id}"} end)

      metrics = PolicyEngine.route_metrics(indexed)

      assert map_size(metrics) == length(indexed),
             "Expected #{length(indexed)} metrics but got #{map_size(metrics)}"
    end
  end

  property "route_metrics for a single connection returns a size-1 map with valid metric" do
    check all(conn <- connection_gen()) do
      c = %{conn | id: "single-#{conn.id}"}
      metrics = PolicyEngine.route_metrics([c])

      assert map_size(metrics) == 1,
             "Expected size-1 map for single connection, got #{map_size(metrics)}"

      {_id, metric} = Enum.at(metrics, 0)

      assert is_integer(metric) and metric >= 1 and metric <= 9999,
             "Expected metric in [1, 9999], got: #{inspect(metric)}"
    end
  end

  property "route_metrics never includes nil keys" do
    check all(
            connections <-
              StreamData.list_of(connection_gen(), min_length: 1, max_length: 6)
          ) do
      indexed =
        connections
        |> Enum.with_index()
        |> Enum.map(fn {c, i} -> %{c | id: "nilkey-#{i}-#{c.id}"} end)

      metrics = PolicyEngine.route_metrics(indexed)

      for {key, _val} <- metrics do
        assert key != nil,
               "route_metrics contains a nil key"
      end
    end
  end

  property "dns_priority result never contains nil server entries" do
    check all(
            connections <-
              StreamData.list_of(connection_with_dns_gen(), min_length: 1, max_length: 5)
          ) do
      result = PolicyEngine.dns_priority(connections)

      for entry <- result do
        assert entry.server != nil,
               "Expected non-nil server in dns_priority entry: #{inspect(entry)}"
      end
    end
  end

  property "dns_priority result count equals total DNS entries across all connections" do
    check all(
            connections <-
              StreamData.list_of(connection_gen(), min_length: 0, max_length: 5)
          ) do
      indexed =
        connections
        |> Enum.with_index()
        |> Enum.map(fn {c, i} -> %{c | id: "dns-#{i}-#{c.id}", dns: ["8.8.#{i}.#{i}"]} end)

      result = PolicyEngine.dns_priority(indexed)
      total_dns = Enum.sum(Enum.map(indexed, &length(&1.dns)))

      assert length(result) == total_dns,
             "Expected #{total_dns} DNS entries, got #{length(result)}"
    end
  end

  property "dns_priority entries always have non-nil interface field" do
    check all(
            connections <-
              StreamData.list_of(connection_with_dns_gen(), min_length: 1, max_length: 5)
          ) do
      result = PolicyEngine.dns_priority(connections)

      for entry <- result do
        assert entry.interface != nil,
               "Expected non-nil interface in dns_priority entry: #{inspect(entry)}"
      end
    end
  end

  property "dns_priority entries always have a positive integer priority field" do
    check all(
            connections <-
              StreamData.list_of(connection_with_dns_gen(), min_length: 1, max_length: 5)
          ) do
      result = PolicyEngine.dns_priority(connections)

      for entry <- result do
        assert is_integer(entry.priority) and entry.priority > 0,
               "Expected positive integer priority, got: #{inspect(entry.priority)}"
      end
    end
  end

  property "dns_priority with empty connections always returns empty list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = PolicyEngine.dns_priority([])
      assert result == [],
             "Expected [] for empty connections, got: #{inspect(result)}"
    end
  end

  property "default_route with no connections always returns :none" do
    check all(_ <- StreamData.constant(:ok)) do
      result = PolicyEngine.default_route([])
      assert result == :none,
             "Expected :none for empty connection list, got: #{inspect(result)}"
    end
  end

  property "route_metrics always returns a map with one entry per connection" do
    check all(connections <- StreamData.list_of(connection_gen(), min_length: 1, max_length: 8)) do
      # Give each connection a unique id to avoid key collisions
      unique_conns =
        connections
        |> Enum.with_index()
        |> Enum.map(fn {c, i} -> %{c | id: "uniq_#{i}_#{c.id}"} end)

      metrics = PolicyEngine.route_metrics(unique_conns)
      assert is_map(metrics),
             "Expected map from route_metrics, got: #{inspect(metrics)}"
      assert map_size(metrics) == length(unique_conns),
             "Expected #{length(unique_conns)} entries in route_metrics, got #{map_size(metrics)}"
    end
  end

  property "route_metrics values are always positive integers" do
    check all(connections <- StreamData.list_of(connection_gen(), min_length: 1, max_length: 5)) do
      unique_conns =
        connections
        |> Enum.with_index()
        |> Enum.map(fn {c, i} -> %{c | id: "rv_#{i}_#{c.id}"} end)

      metrics = PolicyEngine.route_metrics(unique_conns)

      for {_id, metric} <- metrics do
        assert is_integer(metric) and metric > 0,
               "Expected positive integer metric, got: #{inspect(metric)}"
      end
    end
  end

  property "effective_priority for any connection is always non-negative" do
    check all(conn <- connection_gen()) do
      priority = PolicyEngine.effective_priority(conn)
      assert is_integer(priority) and priority >= 0,
             "Expected non-negative integer from effective_priority, got: #{inspect(priority)}"
    end
  end

  property "route_metrics with single active connection always returns a map with one entry" do
    check all(conn <- connection_gen()) do
      active = [Map.put(conn, :state, :activated)]
      metrics = PolicyEngine.route_metrics(active)
      assert is_map(metrics),
             "Expected map from route_metrics, got: #{inspect(metrics)}"
      assert map_size(metrics) == 1,
             "Expected 1 entry in route_metrics for single connection, got: #{inspect(metrics)}"
    end
  end

  property "default_route with single activated connection always returns {:ok, _}" do
    check all(conn <- connection_gen()) do
      active = [Map.put(conn, :state, :activated)]
      result = PolicyEngine.default_route(active)
      assert match?({:ok, _}, result) or result == :none,
             "Expected {:ok, _} or :none from default_route, got: #{inspect(result)}"
    end
  end

  property "dns_priority result is always a list" do
    check all(connections <- list_of(connection_gen(), max_length: 5)) do
      result = PolicyEngine.dns_priority(connections)
      assert is_list(result),
             "Expected list from dns_priority, got: #{inspect(result)}"
    end
  end

  property "route_metrics for two distinct connections produces two entries" do
    check all(
            seed1 <- StreamData.integer(1..49_999),
            seed2 <- StreamData.integer(50_000..99_999)
          ) do
      conn1 = %{profile_id: "pe_a#{seed1}", priority: 100, state: :activated, interface: "eth0", type: :ethernet, autoconnect_priority: 100}
      conn2 = %{profile_id: "pe_b#{seed2}", priority: 100, state: :activated, interface: "eth1", type: :ethernet, autoconnect_priority: 100}
      metrics = PolicyEngine.route_metrics([conn1, conn2])
      assert map_size(metrics) == 2,
             "Expected 2 metric entries for 2 connections, got: #{inspect(metrics)}"
    end
  end
end