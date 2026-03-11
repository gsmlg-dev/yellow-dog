defmodule YellowDog.ResolvedTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved
  alias YellowDog.Resolved.{Cache, Config, Counters, Forwarder, RateLimiter}

  @test_config %{
    listen: {127, 0, 0, 1},
    port: 15353,
    upstreams: [{8, 8, 8, 8}],
    upstream_timeout_ms: 1000,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 1000,
      min_ttl_s: 5,
      max_ttl_s: 3600,
      negative_ttl_s: 30,
      sweep_interval_s: 3600
    },
    discovery: %{enabled: false, websocket: %{}},
    rate_limit: %{burst: 50, rate: 20},
    intercept_rules: [
      %{match: {:exact, "test.local"}, type: :a, value: "127.0.0.1", ttl: 300}
    ]
  }

  setup do
    start_supervised!({Config, @test_config})
    start_supervised!(Counters)
    start_supervised!({Cache, @test_config.cache})
    start_supervised!({Forwarder, @test_config})
    start_supervised!({RateLimiter, @test_config})
    :ok
  end

  describe "status/0" do
    test "returns a complete status snapshot" do
      status = Resolved.status()

      assert is_map(status.config)
      assert status.config.port == 15353
      assert status.config.upstreams == [{8, 8, 8, 8}]
      assert status.config.intercept_rule_count == 1

      assert is_map(status.counters)
      assert is_integer(status.counters.total)

      assert is_map(status.cache)
      assert is_integer(status.cache.entries)
      assert is_integer(status.cache.hits)

      assert is_map(status.upstream_latencies)
      assert is_map(status.rate_limiter)
      assert is_integer(status.rate_limiter.tracked_ips)
    end
  end
end
