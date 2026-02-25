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

  describe "catch-all handle_info" do
    test "ignores unexpected messages" do
      pid = Process.whereis(Metrics)
      send(pid, :unexpected)
      Process.sleep(10)
      assert Process.alive?(pid)
    end
  end

  defp build_query(domain, type_num) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
  end
end
