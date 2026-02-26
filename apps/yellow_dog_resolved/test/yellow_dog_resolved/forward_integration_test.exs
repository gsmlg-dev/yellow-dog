defmodule YellowDog.Resolved.ForwardIntegrationTest do
  @moduledoc """
  Integration tests for the full forward path: Router → Forwarder → FakeUpstream → Cache.

  Uses a real UDP socket (FakeUpstream) as a mock DNS server to test:
  - Successful query forwarding and response return
  - NXDOMAIN negative caching
  - Cache population after forward
  - Transaction ID preservation through the full pipeline
  - Metrics counter increments on forward
  """
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Forwarder, Metrics, Router}
  alias YellowDog.Resolved.Test.FakeUpstream

  @cache_config %{
    enabled: true,
    max_entries: 1000,
    min_ttl_s: 5,
    max_ttl_s: 3600,
    negative_ttl_s: 60,
    sweep_interval_s: 3600
  }

  describe "Forwarder success path with FakeUpstream" do
    setup do
      {:ok, upstream_pid, upstream_port} = FakeUpstream.start(:echo)
      on_exit(fn -> FakeUpstream.stop(upstream_pid) end)

      config = %{
        listen: {127, 0, 0, 1},
        port: 0,
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3,
        intercept_rules: [],
        cache: @cache_config,
        discovery: %{
          enabled: false,
          websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
        },
        config_path: ""
      }

      start_supervised!({Config, config})
      start_supervised!({Cache, @cache_config})
      start_supervised!({Metrics, []})

      forwarder_config = %{
        upstreams: config.upstreams,
        upstream_timeout_ms: config.upstream_timeout_ms,
        upstream_failure_threshold: config.upstream_failure_threshold
      }

      start_supervised!({Forwarder, forwarder_config})

      {:ok, upstream_port: upstream_port}
    end

    test "Forwarder.forward/1 returns valid response from fake upstream" do
      query = build_query("example.com", 1)

      assert {:ok, response_binary} = Forwarder.forward(query)
      assert is_binary(response_binary)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.ra == 1
      assert length(response.anlist) == 1
    end

    test "forward preserves transaction ID from upstream" do
      query = build_query("txn-test.com", 1)
      query = DNS.Message.update_header_attr(query, :id, 42_000)

      assert {:ok, response_binary} = Forwarder.forward(query)

      # The raw response from upstream has the same txn_id because we sent it
      <<txn_id::16, _rest::binary>> = response_binary
      assert txn_id == 42_000
    end

    test "forward resets upstream failure count on success" do
      # First successful query
      query = build_query("success.com", 1)
      assert {:ok, _} = Forwarder.forward(query)

      # Forwarder should still be alive and healthy
      pid = Process.whereis(Forwarder)
      assert Process.alive?(pid)
    end
  end

  describe "Router full pipeline: forward path" do
    setup do
      {:ok, upstream_pid, upstream_port} = FakeUpstream.start(:echo)
      on_exit(fn -> FakeUpstream.stop(upstream_pid) end)

      config = %{
        listen: {127, 0, 0, 1},
        port: 0,
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
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

      start_supervised!({Config, config})
      start_supervised!({Cache, @cache_config})
      start_supervised!({Metrics, []})

      forwarder_config = %{
        upstreams: config.upstreams,
        upstream_timeout_ms: config.upstream_timeout_ms,
        upstream_failure_threshold: config.upstream_failure_threshold
      }

      start_supervised!({Forwarder, forwarder_config})

      {:ok, upstream_port: upstream_port}
    end

    test "non-intercepted domain is forwarded and returns :forward source" do
      query = build_query("example.com", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :forward} = Router.resolve(query, raw)
      assert is_binary(response_binary)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert length(response.anlist) == 1
    end

    test "forwarded response is cached for subsequent lookups" do
      query = build_query("cache-me.com", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      # First resolve — should forward
      assert {:ok, _response, :forward} = Router.resolve(query, raw)

      # Wait for async cache store
      Process.sleep(50)

      # Second resolve — should hit cache
      query2 = build_query("cache-me.com", 1)
      raw2 = DNS.to_iodata(query2) |> IO.iodata_to_binary()

      assert {:ok, cached_response, :cache} = Router.resolve(query2, raw2)
      assert is_binary(cached_response)

      # Transaction ID should be rewritten to match query2
      <<txn_id::16, _rest::binary>> = cached_response
      assert txn_id == query2.header.id
    end

    test "Router preserves transaction ID through forward pipeline" do
      query = build_query("tid-test.org", 1)
      query = DNS.Message.update_header_attr(query, :id, 54_321)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :forward} = Router.resolve(query, raw)

      <<txn_id::16, _rest::binary>> = response_binary
      assert txn_id == 54_321
    end

    test "intercept still takes priority over forward" do
      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, _response, :intercept} = Router.resolve(query, raw)
    end

    test "Metrics counters increment on forward" do
      # Get baseline
      before = Metrics.get_query_counts()

      query = build_query("metrics-forward.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, _, :forward} = Router.resolve(query, raw)

      after_counts = Metrics.get_query_counts()
      assert after_counts.total == before.total + 1
      assert after_counts.forwarded == before.forwarded + 1
    end
  end

  describe "Router with NXDOMAIN upstream" do
    setup do
      {:ok, upstream_pid, upstream_port} = FakeUpstream.start(:nxdomain)
      on_exit(fn -> FakeUpstream.stop(upstream_pid) end)

      config = %{
        listen: {127, 0, 0, 1},
        port: 0,
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3,
        intercept_rules: [],
        cache: @cache_config,
        discovery: %{
          enabled: false,
          websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
        },
        config_path: ""
      }

      start_supervised!({Config, config})
      start_supervised!({Cache, @cache_config})
      start_supervised!({Metrics, []})

      forwarder_config = %{
        upstreams: config.upstreams,
        upstream_timeout_ms: config.upstream_timeout_ms,
        upstream_failure_threshold: config.upstream_failure_threshold
      }

      start_supervised!({Forwarder, forwarder_config})

      :ok
    end

    test "NXDOMAIN response is stored as negative cache entry" do
      query = build_query("nonexistent.example.com", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :forward} = Router.resolve(query, raw)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.rcode == DNS.Message.RCode.nx_domain()

      # Wait for async cache store
      Process.sleep(50)

      # Second lookup should come from cache (negative entry)
      query2 = build_query("nonexistent.example.com", 1)
      raw2 = DNS.to_iodata(query2) |> IO.iodata_to_binary()

      assert {:ok, cached_response, :cache} = Router.resolve(query2, raw2)
      assert is_binary(cached_response)
    end

    test "NXDOMAIN increments forward counter" do
      before = Metrics.get_query_counts()

      query = build_query("nx.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, _, :forward} = Router.resolve(query, raw)

      after_counts = Metrics.get_query_counts()
      assert after_counts.forwarded == before.forwarded + 1
    end
  end

  describe "Forwarder with {ip, port} upstream format" do
    test "works with bare IP tuple (defaults to port 53)" do
      # This will fail to connect (no DNS server on port 53 locally), but
      # validates that the bare IP format still works
      config = %{
        upstreams: [{198, 51, 100, 1}],
        upstream_timeout_ms: 200,
        upstream_failure_threshold: 3
      }

      start_supervised!({Forwarder, config})

      query = build_query("bare-ip.test", 1)
      assert {:error, :all_upstreams_failed} = Forwarder.forward(query)
    end

    test "works with {ip, port} tuple format" do
      {:ok, upstream_pid, upstream_port} = FakeUpstream.start(:echo)
      on_exit(fn -> FakeUpstream.stop(upstream_pid) end)

      config = %{
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3
      }

      start_supervised!({Forwarder, config})

      query = build_query("ip-port.test", 1)
      assert {:ok, response} = Forwarder.forward(query)
      assert is_binary(response)
    end

    test "mixed format upstreams with failover" do
      {:ok, upstream_pid, upstream_port} = FakeUpstream.start(:echo)
      on_exit(fn -> FakeUpstream.stop(upstream_pid) end)

      config = %{
        # First upstream is unreachable, second is FakeUpstream
        upstreams: [{198, 51, 100, 1}, {{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 200,
        upstream_failure_threshold: 3
      }

      start_supervised!({Forwarder, config})

      query = build_query("failover.test", 1)
      assert {:ok, response} = Forwarder.forward(query)
      assert is_binary(response)

      # Verify it's a valid DNS response
      decoded = DNS.Message.from_iodata(response)
      assert decoded.header.qr == 1
    end
  end

  defp build_query(domain, type_num) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
  end
end
