defmodule YellowDog.Resolved.RouterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Resolved.{Cache, Config, Router}

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
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300},
      %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600}
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
    :ok
  end

  defp build_query(domain, type_num) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
  end

  describe "resolve with intercept" do
    test "returns intercepted response for matching domain" do
      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)
      assert is_binary(response_binary)

      # Decode and verify
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.aa == 1
      assert length(response.anlist) == 1
    end

    test "returns empty answer for mismatched type" do
      # Query AAAA for a domain that only has A rule
      query = build_query("myapp.test", 28)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.anlist == []
    end

    test "intercept preserves query transaction ID" do
      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)

      assert response.header.id == query.header.id
    end

    test "intercept for exact match" do
      query = build_query("myapp.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)

      assert length(response.anlist) == 1
      [record] = response.anlist
      assert record.ttl == 600
    end
  end

  describe "resolve with cache" do
    test "cache hit returns cached response" do
      # Pre-populate cache with a fake response
      query = build_query("cached.example.com", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      # Build a fake response binary
      response = DNS.Message.new()
      response = DNS.Message.update_header_attr(response, :id, 9999)
      response = DNS.Message.update_header_attr(response, :qr, 1)
      response = DNS.Message.update_header_attr(response, :rd, 1)
      response_binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      Cache.store("cached.example.com", :a, response_binary, 300)
      Process.sleep(10)

      assert {:ok, result_binary, :cache} = Router.resolve(query, raw)
      assert is_binary(result_binary)

      # Transaction ID should be rewritten to match query
      <<txn_id::16, _rest::binary>> = result_binary
      assert txn_id == query.header.id
    end
  end

  describe "resolve with empty query" do
    test "returns FORMERR for query without questions" do
      query = DNS.Message.new()
      query = DNS.Message.update_header_attr(query, :id, 1234)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.form_err()
    end
  end

  describe "resolve non-intercepted domain (forward path)" do
    test "returns SERVFAIL when forwarder not started" do
      # No forwarder is started in this test setup — GenServer.call exit
      # Router should catch the exit and return SERVFAIL
      query = build_query("external.com", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      {result, log} =
        with_log(fn ->
          Router.resolve(query, raw)
        end)

      assert {:ok, response_binary} = result
      assert log =~ "Query resolution crashed"

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.serv_fail()
    end
  end

  describe "resolve with garbage upstream response" do
    setup do
      {:ok, upstream_pid, upstream_port} =
        YellowDog.Resolved.Test.FakeUpstream.start(:garbage)

      on_exit(fn -> YellowDog.Resolved.Test.FakeUpstream.stop(upstream_pid) end)

      forwarder_config = %{
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3
      }

      start_supervised!({YellowDog.Resolved.Forwarder, forwarder_config})
      :ok
    end

    test "returns SERVFAIL when upstream responds with invalid data" do
      query = build_query("garbage.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      {result, log} =
        with_log(fn ->
          Router.resolve(query, raw)
        end)

      assert {:ok, response_binary} = result
      # Random bytes can trigger either Elixir exception (rescue) or Erlang throw (catch)
      assert log =~ "Query resolution failed" or log =~ "Query resolution crashed"

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.serv_fail()
    end
  end

  describe "SERVFAIL upstream response is not cached" do
    setup do
      {:ok, upstream_pid, upstream_port} =
        YellowDog.Resolved.Test.FakeUpstream.start(:servfail)

      on_exit(fn -> YellowDog.Resolved.Test.FakeUpstream.stop(upstream_pid) end)

      forwarder_config = %{
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3
      }

      start_supervised!({YellowDog.Resolved.Forwarder, forwarder_config})
      :ok
    end

    test "SERVFAIL from upstream is forwarded but not cached" do
      query = build_query("servfail.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      # First query — should forward and get SERVFAIL
      assert {:ok, response_binary, :forward} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.rcode == DNS.Message.RCode.serv_fail()

      Process.sleep(10)

      # Second query — should NOT come from cache (SERVFAIL is transient)
      assert :miss = Cache.lookup("servfail.test", :a)
    end
  end

  describe "NODATA (NOERROR with empty answer) caching" do
    setup do
      {:ok, upstream_pid, upstream_port} =
        YellowDog.Resolved.Test.FakeUpstream.start(:noerror_empty)

      on_exit(fn -> YellowDog.Resolved.Test.FakeUpstream.stop(upstream_pid) end)

      forwarder_config = %{
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3
      }

      start_supervised!({YellowDog.Resolved.Forwarder, forwarder_config})
      :ok
    end

    test "NODATA response is cached (NOERROR rcode)" do
      query = build_query("nodata.test", 28)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :forward} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.rcode == DNS.Message.RCode.new(0)
      assert response.anlist == []

      Process.sleep(10)

      # NOERROR is cached even with empty answer (NODATA scenario)
      assert {:hit, _} = Cache.lookup("nodata.test", :aaaa)
    end

    test "NODATA cached response preserves empty answer on second query" do
      query = build_query("nodata-preserve.test", 28)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      Router.resolve(query, raw)
      Process.sleep(10)

      # Second query should hit cache
      query2 = build_query("nodata-preserve.test", 28)
      raw2 = DNS.to_iodata(query2) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :cache} = Router.resolve(query2, raw2)
      response = DNS.Message.from_iodata(response_binary)
      assert response.anlist == []
    end
  end

  describe "multiple intercept rules for same domain with different types" do
    setup do
      # Override Config with rules that have both A and AAAA for the same suffix
      multi_config = %{
        @config
        | intercept_rules: [
            %{match: {:suffix, "multi.dev"}, type: :a, value: "10.0.0.1", ttl: 60},
            %{match: {:suffix, "multi.dev"}, type: :aaaa, value: "::1", ttl: 120}
          ]
      }

      stop_supervised!(Config)
      start_supervised!({Config, multi_config})
      :ok
    end

    test "A query matches the A rule" do
      query = build_query("app.multi.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)
      assert length(response.anlist) == 1
      assert response.header.rcode == DNS.Message.RCode.new(0)
    end

    test "AAAA query still matches first rule (first-match-wins) with empty answer" do
      # The first rule is :a, so AAAA query hits type mismatch → empty answer
      query = build_query("app.multi.dev", 28)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)
      # First rule matches domain but type differs → empty answer
      assert response.anlist == []
      assert response.header.rcode == DNS.Message.RCode.new(0)
    end
  end

  describe "NXDOMAIN caching through full pipeline" do
    setup do
      {:ok, upstream_pid, upstream_port} =
        YellowDog.Resolved.Test.FakeUpstream.start(:nxdomain)

      on_exit(fn -> YellowDog.Resolved.Test.FakeUpstream.stop(upstream_pid) end)

      forwarder_config = %{
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3
      }

      start_supervised!({YellowDog.Resolved.Forwarder, forwarder_config})
      :ok
    end

    test "NXDOMAIN is cached as negative entry" do
      query = build_query("nxdomain-cache.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :forward} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.rcode == DNS.Message.RCode.nx_domain()

      Process.sleep(10)

      # Second query should come from cache
      query2 = build_query("nxdomain-cache.test", 1)
      raw2 = DNS.to_iodata(query2) |> IO.iodata_to_binary()

      assert {:ok, _response_binary2, :cache} = Router.resolve(query2, raw2)
    end

    test "NXDOMAIN cached response preserves rcode" do
      query = build_query("nxdomain-rcode.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      Router.resolve(query, raw)
      Process.sleep(10)

      query2 = build_query("nxdomain-rcode.test", 1)
      raw2 = DNS.to_iodata(query2) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :cache} = Router.resolve(query2, raw2)
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.rcode == DNS.Message.RCode.nx_domain()
    end
  end

  describe "safe query type handling" do
    test "standard types resolve correctly through intercept" do
      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, _, :intercept} = Router.resolve(query, raw)
    end

    test "unknown query type doesn't crash router" do
      # Type 99 (SPF) is not in the known types map — should map to :unknown
      query = build_query("app.local.dev", 99)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
    end

    test "FORMERR for query without questions preserves txn_id" do
      query = DNS.Message.new()
      query = DNS.Message.update_header_attr(query, :id, 42_000)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.id == 42_000
      assert response.header.rcode == DNS.Message.RCode.form_err()
    end
  end

  describe "telemetry exception event" do
    test "emits query exception telemetry when forwarder crashes" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "router-exception-#{inspect(ref)}",
        [:yellow_dog, :resolved, :query, :exception],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:query_exception, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("router-exception-#{inspect(ref)}") end)

      # Query a non-intercepted domain with no Forwarder running → crash → exception telemetry
      query = build_query("exception-telemetry.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      capture_log(fn ->
        Router.resolve(query, raw)
      end)

      assert_receive {:query_exception, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.domain == "unknown"
      assert metadata.type == :unknown
    end
  end

  describe "config hot-reload affects resolution" do
    test "new intercept rules take effect after reload" do
      # Initially, "new-domain.test" is NOT intercepted
      query = build_query("new-domain.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      result =
        capture_log(fn ->
          send(self(), {:result, Router.resolve(query, raw)})
        end)

      assert_received {:result, resolved}
      _ = result

      # Should NOT be intercepted (no matching rule)
      case resolved do
        {:ok, _, :intercept} -> flunk("Should not be intercepted yet")
        _ -> :ok
      end

      # Hot-reload config with new intercept rule
      new_config = %{
        @config
        | intercept_rules: [
            %{match: {:exact, "new-domain.test"}, type: :a, value: "10.10.10.10", ttl: 120}
          ]
      }

      pid = Process.whereis(Config)
      :sys.replace_state(pid, fn state -> %{state | config: new_config} end)

      # Now query should be intercepted
      query2 = build_query("new-domain.test", 1)
      raw2 = DNS.to_iodata(query2) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query2, raw2)
      response = DNS.Message.from_iodata(response_binary)
      assert length(response.anlist) == 1
    end
  end

  describe "forward-and-cache TTL extraction" do
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

    test "forwarded NOERROR response is cached with TTL from answer records" do
      query = build_query("ttl-extract.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, _response_binary, :forward} = Router.resolve(query, raw)
      Process.sleep(10)

      # FakeUpstream :echo returns A record with TTL=60
      # Cache should have the entry
      assert {:hit, _} = Cache.lookup("ttl-extract.test", :a)

      # Inspect ETS to verify expires_at is reasonable
      [{_key, _resp, expires_at, _last, _neg}] =
        :ets.lookup(YellowDog.Resolved.Cache, {"ttl-extract.test", :a})

      now = System.monotonic_time(:second)
      remaining = expires_at - now

      # FakeUpstream TTL=60, but clamped by min_ttl_s=5, max_ttl_s=3600
      # So remaining should be close to 60 (between 50 and 65 accounting for test timing)
      assert remaining >= 50
      assert remaining <= 65
    end

    test "second query for same domain comes from cache" do
      query1 = build_query("cache-forward.test", 1)
      raw1 = DNS.to_iodata(query1) |> IO.iodata_to_binary()
      assert {:ok, _, :forward} = Router.resolve(query1, raw1)

      Process.sleep(10)

      query2 = build_query("cache-forward.test", 1)
      raw2 = DNS.to_iodata(query2) |> IO.iodata_to_binary()
      assert {:ok, _, :cache} = Router.resolve(query2, raw2)
    end
  end
end
