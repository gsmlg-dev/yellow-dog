defmodule YellowDog.Resolved.MetricsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Metrics, Router}

  @cache_config %{
    enabled: true,
    max_entries: 1000,
    min_ttl_s: 5,
    max_ttl_s: 3600,
    negative_ttl_s: 60,
    sweep_interval_s: 3600
  }

  @config %{
    listen: {127, 0, 0, 1},
    port: 0,
    upstreams: [{198, 51, 100, 1}],
    upstream_timeout_ms: 200,
    upstream_failure_threshold: 3,
    intercept_rules: [
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300}
    ],
    cache: @cache_config,
    discovery: %{
      enabled: false,
      websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
    },
    config_path: ""
  }

  setup do
    start_supervised!({Config, @config})
    start_supervised!({Cache, @cache_config})
    start_supervised!(Metrics)
    :ok
  end

  describe "get_query_counts/0" do
    test "returns zero counts initially" do
      counts = Metrics.get_query_counts()

      assert counts.total == 0
      assert counts.intercepted == 0
      assert counts.cached == 0
      assert counts.forwarded == 0
    end

    test "increments intercept counter on intercepted query" do
      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      Router.resolve(query, raw)

      counts = Metrics.get_query_counts()
      assert counts.total == 1
      assert counts.intercepted == 1
      assert counts.cached == 0
      assert counts.forwarded == 0
    end

    test "increments on multiple queries" do
      for i <- 1..5 do
        query = build_query("app#{i}.local.dev", 1)
        raw = DNS.to_iodata(query) |> IO.iodata_to_binary()
        Router.resolve(query, raw)
      end

      counts = Metrics.get_query_counts()
      assert counts.total == 5
      assert counts.intercepted == 5
    end
  end

  describe "cache counter" do
    test "increments cached counter on cache hit" do
      # Pre-populate cache
      query = build_query("cached-metrics.test", 1)
      response = DNS.Message.new()
      response = DNS.Message.update_header_attr(response, :id, 9999)
      response = DNS.Message.update_header_attr(response, :qr, 1)
      response_binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      Cache.store("cached-metrics.test.", :a, response_binary, 300)
      Process.sleep(10)

      before = Metrics.get_query_counts()

      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()
      Router.resolve(query, raw)

      counts = Metrics.get_query_counts()
      assert counts.total == before.total + 1
      assert counts.cached == before.cached + 1
    end
  end

  describe "forward counter" do
    setup do
      {:ok, upstream_pid, upstream_port} =
        YellowDog.Resolved.Test.FakeUpstream.start(:echo)

      on_exit(fn -> YellowDog.Resolved.Test.FakeUpstream.stop(upstream_pid) end)

      forwarder_config = %{
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3
      }

      start_supervised!({YellowDog.Resolved.Forwarder, forwarder_config})
      :ok
    end

    test "increments forwarded counter on upstream query" do
      before = Metrics.get_query_counts()

      query = build_query("forward-metrics.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()
      Router.resolve(query, raw)

      counts = Metrics.get_query_counts()
      assert counts.total == before.total + 1
      assert counts.forwarded == before.forwarded + 1
    end
  end

  describe "concurrent counter updates" do
    test "counters are accurate under concurrent load" do
      # Verify handler is attached before concurrent burst
      handlers = :telemetry.list_handlers([:yellow_dog, :resolved, :query, :stop])
      assert Enum.any?(handlers, &(&1.id == "resolved-metrics-query-stop"))

      # Warm up — ensure ETS table and telemetry pipeline are fully ready
      warmup = build_query("warmup.local.dev", 1)
      warmup_raw = DNS.to_iodata(warmup) |> IO.iodata_to_binary()
      Router.resolve(warmup, warmup_raw)

      before = Metrics.get_query_counts()
      n = 50

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            query = build_query("concurrent-#{i}.local.dev", 1)
            raw = DNS.to_iodata(query) |> IO.iodata_to_binary()
            Router.resolve(query, raw)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      counts = Metrics.get_query_counts()
      assert counts.total == before.total + n
      assert counts.intercepted == before.intercepted + n
    end

    test "forwarded counters accurate under concurrent load" do
      {:ok, upstream_pid, upstream_port} =
        YellowDog.Resolved.Test.FakeUpstream.start(:echo)

      on_exit(fn -> YellowDog.Resolved.Test.FakeUpstream.stop(upstream_pid) end)

      forwarder_config = %{
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3
      }

      start_supervised!({YellowDog.Resolved.Forwarder, forwarder_config})

      before = Metrics.get_query_counts()
      n = 20

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            query = build_query("concurrent-fwd-#{i}.test", 1)
            raw = DNS.to_iodata(query) |> IO.iodata_to_binary()
            Router.resolve(query, raw)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      counts = Metrics.get_query_counts()
      assert counts.forwarded >= before.forwarded + n
    end
  end

  describe "unknown source in query:stop telemetry" do
    test "unknown source only increments total (not intercept/cache/forward)" do
      before = Metrics.get_query_counts()

      # Emit telemetry directly with an unknown source
      :telemetry.execute(
        [:yellow_dog, :resolved, :query, :stop],
        %{duration: 1000},
        %{domain: "test.example", type: :a, source: :unknown_source}
      )

      counts = Metrics.get_query_counts()
      assert counts.total == before.total + 1
      assert counts.intercepted == before.intercepted
      assert counts.cached == before.cached
      assert counts.forwarded == before.forwarded
    end

    test "nil source only increments total" do
      before = Metrics.get_query_counts()

      :telemetry.execute(
        [:yellow_dog, :resolved, :query, :stop],
        %{duration: 0},
        %{domain: "nil-source.test", type: :a, source: nil}
      )

      counts = Metrics.get_query_counts()
      assert counts.total == before.total + 1
      assert counts.intercepted == before.intercepted
    end

    test "error source only increments total" do
      before = Metrics.get_query_counts()

      :telemetry.execute(
        [:yellow_dog, :resolved, :query, :stop],
        %{duration: 0},
        %{domain: "error.test", type: :a, source: :error}
      )

      counts = Metrics.get_query_counts()
      assert counts.total == before.total + 1
      assert counts.forwarded == before.forwarded
    end
  end

  describe "ETS table resilience (catch :badarg paths)" do
    test "get_query_counts returns zeros when ETS table is deleted" do
      # Bump some counters first
      :telemetry.execute(
        [:yellow_dog, :resolved, :query, :stop],
        %{duration: 0},
        %{domain: "ets.test", type: :a, source: :intercept}
      )

      counts_before = Metrics.get_query_counts()
      assert counts_before.total >= 1

      # Delete the ETS table
      :ets.delete(:resolved_metrics)

      # Should return zeros (catch :badarg), not crash
      counts = Metrics.get_query_counts()
      assert counts.total == 0
      assert counts.intercepted == 0
      assert counts.cached == 0
      assert counts.forwarded == 0
    end

    test "telemetry handler survives ETS table deletion" do
      :ets.delete(:resolved_metrics)

      # Emitting telemetry should not crash — bump/1 catches :badarg
      :telemetry.execute(
        [:yellow_dog, :resolved, :query, :stop],
        %{duration: 0},
        %{domain: "resilient.test", type: :a, source: :intercept}
      )

      # Handler should still be attached
      handlers = :telemetry.list_handlers([:yellow_dog, :resolved, :query, :stop])
      assert Enum.any?(handlers, &(&1.id == "resolved-metrics-query-stop"))
    end
  end

  describe "catch-all handle_info" do
    test "ignores unexpected messages" do
      pid = Process.whereis(Metrics)
      send(pid, :unexpected)
      Process.sleep(10)
      assert Process.alive?(pid)
    end
  end

  describe "terminate/2" do
    test "stops cleanly without crash" do
      pid = Process.whereis(Metrics)
      assert Process.alive?(pid)

      stop_supervised!(Metrics)

      refute Process.alive?(pid)
    end

    test "detaches telemetry handler on shutdown" do
      pid = Process.whereis(Metrics)

      # Verify the handler exists before stopping
      handlers = :telemetry.list_handlers([:yellow_dog, :resolved, :query, :stop])
      assert Enum.any?(handlers, &(&1.id == "resolved-metrics-query-stop"))

      # GenServer.stop guarantees terminate/2 is called
      GenServer.stop(pid, :normal)

      # Handler should be detached after terminate
      handlers_after = :telemetry.list_handlers([:yellow_dog, :resolved, :query, :stop])
      refute Enum.any?(handlers_after, &(&1.id == "resolved-metrics-query-stop"))
    end
  end

  defp build_query(domain, type_num) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
  end
end
