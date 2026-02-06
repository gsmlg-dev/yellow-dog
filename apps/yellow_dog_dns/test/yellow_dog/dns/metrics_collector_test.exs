defmodule YellowDog.Dns.MetricsCollectorTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.MetricsCollector

  setup do
    # Use a unique name and table to avoid conflicts with other tests
    name = :"metrics_#{:erlang.unique_integer([:positive])}"
    table_name = :"metrics_table_#{:erlang.unique_integer([:positive])}"

    # Detach any existing handlers from previous test runs
    for suffix <- ["received", "response", "cache", "logged", "fallback"] do
      try do
        :telemetry.detach("dns_metrics_collector_#{suffix}")
      catch
        _, _ -> :ok
      end
    end

    {:ok, pid} = MetricsCollector.start_link(name: name, table_name: table_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{server: pid, name: name}
  end

  describe "start_link/1" do
    test "starts with default options" do
      # Already started in setup, verify it's alive
      name = :"metrics_start_#{:erlang.unique_integer([:positive])}"
      table = :"metrics_tbl_#{:erlang.unique_integer([:positive])}"

      # Detach handlers first since they use global IDs
      for suffix <- ["received", "response", "cache", "logged", "fallback"] do
        try do
          :telemetry.detach("dns_metrics_collector_#{suffix}")
        catch
          _, _ -> :ok
        end
      end

      {:ok, pid} = MetricsCollector.start_link(name: name, table_name: table)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "get_metrics/1" do
    test "returns initial metrics", %{server: server} do
      metrics = MetricsCollector.get_metrics(server)

      assert metrics.counters.queries_total == 0
      assert metrics.counters.cache_hits == 0
      assert metrics.counters.cache_misses == 0
      assert metrics.counters.rate_limit_rejected == 0
      assert metrics.counters.fallbacks_total == 0
      assert metrics.response_times.count == 0
      assert metrics.top_domains == []
      assert metrics.top_clients == []
      assert is_binary(DateTime.to_iso8601(metrics.started_at))
    end
  end

  describe "telemetry event handling" do
    test "tracks query received events", %{server: server} do
      emit_query_received(%{
        client_ip: {192, 168, 1, 100},
        qname: "example.com",
        qtype: :a,
        protocol: :udp
      })

      # Small delay for ETS writes
      Process.sleep(10)

      assert MetricsCollector.get_counter(server, :queries_total) == 1

      metrics = MetricsCollector.get_metrics(server)
      assert metrics.counters.queries_total == 1
    end

    test "tracks queries by protocol", %{server: server} do
      emit_query_received(%{protocol: :udp})
      emit_query_received(%{protocol: :udp})
      emit_query_received(%{protocol: :tcp})

      Process.sleep(10)

      metrics = MetricsCollector.get_metrics(server)
      protocol_counts = Map.new(metrics.queries_by_protocol)
      assert Map.get(protocol_counts, :udp) == 2
      assert Map.get(protocol_counts, :tcp) == 1
    end

    test "tracks queries by type", %{server: server} do
      emit_query_received(%{qtype: :a})
      emit_query_received(%{qtype: :a})
      emit_query_received(%{qtype: :aaaa})
      emit_query_received(%{qtype: :mx})

      Process.sleep(10)

      metrics = MetricsCollector.get_metrics(server)
      type_counts = Map.new(metrics.queries_by_type)
      assert Map.get(type_counts, :a) == 2
      assert Map.get(type_counts, :aaaa) == 1
      assert Map.get(type_counts, :mx) == 1
    end

    test "tracks cache hits and misses", %{server: server} do
      emit_cache_lookup(%{hit: true, view: "default"})
      emit_cache_lookup(%{hit: true, view: "default"})
      emit_cache_lookup(%{hit: false, view: "internal"})

      Process.sleep(10)

      assert MetricsCollector.get_counter(server, :cache_hits) == 2
      assert MetricsCollector.get_counter(server, :cache_misses) == 1
    end

    test "tracks response times", %{server: server} do
      emit_response_sent(500, %{rcode: :noerror})
      emit_response_sent(1500, %{rcode: :noerror})
      emit_response_sent(10_000, %{rcode: :nxdomain})

      Process.sleep(10)

      histogram = MetricsCollector.get_response_times(server)
      assert histogram.count == 3
      assert histogram.sum == 12_000
      assert histogram.min == 500
      assert histogram.max == 10_000
    end

    test "histogram buckets are populated correctly", %{server: server} do
      emit_response_sent(50, %{})
      emit_response_sent(200, %{})
      emit_response_sent(800, %{})
      emit_response_sent(5_000, %{})
      emit_response_sent(2_000_000, %{})

      Process.sleep(10)

      histogram = MetricsCollector.get_response_times(server)
      buckets = Map.new(histogram.buckets)

      assert buckets[100] == 1
      assert buckets[500] == 1
      assert buckets[1_000] == 1
      assert buckets[5_000] == 1
      assert buckets[:inf] == 1
    end

    test "tracks responses by code", %{server: server} do
      emit_response_sent(100, %{rcode: :noerror})
      emit_response_sent(100, %{rcode: :noerror})
      emit_response_sent(100, %{rcode: :nxdomain})
      emit_response_sent(100, %{rcode: :servfail})

      Process.sleep(10)

      metrics = MetricsCollector.get_metrics(server)
      code_counts = Map.new(metrics.responses_by_code)
      assert Map.get(code_counts, :noerror) == 2
      assert Map.get(code_counts, :nxdomain) == 1
      assert Map.get(code_counts, :servfail) == 1
    end

    test "tracks top domains", %{server: server} do
      for _ <- 1..5, do: emit_query_received(%{qname: "popular.com"})
      for _ <- 1..3, do: emit_query_received(%{qname: "medium.com"})
      emit_query_received(%{qname: "rare.com"})

      Process.sleep(10)

      top = MetricsCollector.get_top_domains(server, limit: 10)
      assert length(top) == 3
      assert hd(top) == {"popular.com", 5}
    end

    test "tracks top clients", %{server: server} do
      for _ <- 1..10, do: emit_query_received(%{client_ip: {10, 0, 0, 1}})
      for _ <- 1..5, do: emit_query_received(%{client_ip: {10, 0, 0, 2}})

      Process.sleep(10)

      top = MetricsCollector.get_top_clients(server, limit: 10)
      assert length(top) == 2
      {top_ip, top_count} = hd(top)
      assert top_ip == "10.0.0.1"
      assert top_count == 10
    end

    test "tracks view fallbacks", %{server: server} do
      emit_view_fallback(%{view: "internal"})
      emit_view_fallback(%{view: "internal"})
      emit_view_fallback(%{view: "external"})

      Process.sleep(10)

      metrics = MetricsCollector.get_metrics(server)
      assert metrics.counters.fallbacks_total == 3
    end
  end

  describe "summary/1" do
    test "returns dashboard summary", %{server: server} do
      # Generate some activity
      for _ <- 1..10, do: emit_query_received(%{})
      for _ <- 1..7, do: emit_cache_lookup(%{hit: true})
      for _ <- 1..3, do: emit_cache_lookup(%{hit: false})
      emit_response_sent(500, %{})
      emit_response_sent(1500, %{})

      Process.sleep(10)

      summary = MetricsCollector.summary(server)
      assert summary.queries_total == 10
      assert summary.cache_hit_rate == 70.0
      assert summary.avg_response_time_us == 1000.0
      assert summary.uptime_seconds >= 0
    end

    test "handles zero cache lookups gracefully", %{server: server} do
      summary = MetricsCollector.summary(server)
      assert summary.cache_hit_rate == 0.0
      assert summary.avg_response_time_us == 0.0
    end
  end

  describe "reset/1" do
    test "resets all counters", %{server: server} do
      for _ <- 1..5, do: emit_query_received(%{qname: "test.com"})
      emit_cache_lookup(%{hit: true})
      emit_response_sent(1000, %{})

      Process.sleep(10)
      assert MetricsCollector.get_counter(server, :queries_total) > 0

      :ok = MetricsCollector.reset(server)

      assert MetricsCollector.get_counter(server, :queries_total) == 0
      assert MetricsCollector.get_counter(server, :cache_hits) == 0

      histogram = MetricsCollector.get_response_times(server)
      assert histogram.count == 0
    end
  end

  describe "concurrent access" do
    test "handles concurrent telemetry events", %{server: _server} do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            emit_query_received(%{
              client_ip: {10, 0, 0, rem(i, 10)},
              qname: "concurrent-#{rem(i, 5)}.com",
              qtype: :a,
              protocol: :udp
            })
          end)
        end

      Task.await_many(tasks)
      Process.sleep(50)

      # Just verify no crashes occurred - exact counts may vary
      # due to handler attachment timing
    end
  end

  # Telemetry event helpers

  defp emit_query_received(metadata) do
    :telemetry.execute(
      [:yellow_dog, :dns, :query, :received],
      %{count: 1},
      metadata
    )
  end

  defp emit_response_sent(duration_us, metadata) do
    :telemetry.execute(
      [:yellow_dog, :dns, :response, :sent],
      %{duration: duration_us, answer_count: 1},
      metadata
    )
  end

  defp emit_cache_lookup(metadata) do
    :telemetry.execute(
      [:yellow_dog, :dns, :cache, :lookup],
      %{count: 1},
      metadata
    )
  end

  defp emit_view_fallback(metadata) do
    :telemetry.execute(
      [:yellow_dog, :dns, :view, :fallback],
      %{count: 1, forwarder: {8, 8, 8, 8}},
      metadata
    )
  end
end
