defmodule YellowDog.RateLimiterTest do
  use ExUnit.Case, async: true

  alias YellowDog.RateLimiter

  describe "normalize_client_id/1" do
    test "passes through binary unchanged" do
      assert RateLimiter.normalize_client_id("client-1") == "client-1"
    end

    test "converts IPv4 tuple to 4-byte binary" do
      result = RateLimiter.normalize_client_id({192, 168, 1, 1})
      assert result == <<192, 168, 1, 1>>
    end

    test "converts IPv6 tuple to 16-byte binary" do
      result = RateLimiter.normalize_client_id({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      assert byte_size(result) == 16
      assert <<0x2001::16, 0x0DB8::16, _rest::binary>> = result
    end

    test "inspects other types" do
      assert RateLimiter.normalize_client_id(:atom) == ":atom"
      assert RateLimiter.normalize_client_id(42) == "42"
    end
  end

  describe "check_global_limit/2" do
    test "allows when tokens available" do
      state = %{
        global_tokens: 10,
        global_last_update: System.monotonic_time(:millisecond),
        config: %{global_tokens: 100, global_refill_rate: 10}
      }

      {allowed, tokens, _time} = RateLimiter.check_global_limit(state, System.monotonic_time(:millisecond))
      assert allowed
      assert tokens >= 10
    end

    test "denies when no tokens available" do
      now = System.monotonic_time(:millisecond)

      state = %{
        global_tokens: 0,
        global_last_update: now,
        config: %{global_tokens: 100, global_refill_rate: 0}
      }

      {allowed, tokens, _time} = RateLimiter.check_global_limit(state, now)
      refute allowed
      assert tokens == 0
    end

    test "refills tokens based on elapsed time" do
      now = System.monotonic_time(:millisecond)

      state = %{
        global_tokens: 0,
        global_last_update: now - 2000,
        config: %{global_tokens: 100, global_refill_rate: 10}
      }

      {allowed, tokens, _time} = RateLimiter.check_global_limit(state, now)
      assert allowed
      assert tokens >= 10
    end

    test "caps tokens at max" do
      now = System.monotonic_time(:millisecond)

      state = %{
        global_tokens: 95,
        global_last_update: now - 10_000,
        config: %{global_tokens: 100, global_refill_rate: 100}
      }

      {allowed, tokens, _time} = RateLimiter.check_global_limit(state, now)
      assert allowed
      assert tokens == 100
    end
  end

  describe "load_config/4" do
    test "returns default config when no overrides" do
      config = RateLimiter.load_config(:yellow_dog, :nonexistent_module, %{port: 80}, [])
      assert config.port == 80
    end

    test "opts override defaults" do
      config = RateLimiter.load_config(:yellow_dog, :nonexistent_module, %{port: 80}, port: 9090)
      assert config.port == 9090
    end
  end

  describe "check_client_limit/4" do
    setup do
      table = :ets.new(:test_rate_limiter, [:public])
      %{table: table}
    end

    test "allows first request from new client", %{table: table} do
      config = %{client_tokens: 10, client_refill_rate: 2}
      now = System.monotonic_time(:millisecond)

      {allowed, tokens} = RateLimiter.check_client_limit(table, "client-1", config, now)
      assert allowed
      assert tokens == 9
    end

    test "tracks tokens across requests", %{table: table} do
      config = %{client_tokens: 3, client_refill_rate: 0}
      now = System.monotonic_time(:millisecond)

      {true, 2} = RateLimiter.check_client_limit(table, "c1", config, now)
      {true, 1} = RateLimiter.check_client_limit(table, "c1", config, now)
      {true, 0} = RateLimiter.check_client_limit(table, "c1", config, now)
      {false, _} = RateLimiter.check_client_limit(table, "c1", config, now)
    end

    test "refills client tokens over time", %{table: table} do
      config = %{client_tokens: 2, client_refill_rate: 10}
      now = System.monotonic_time(:millisecond)

      {true, 1} = RateLimiter.check_client_limit(table, "c1", config, now)
      {true, 0} = RateLimiter.check_client_limit(table, "c1", config, now)
      {false, _} = RateLimiter.check_client_limit(table, "c1", config, now)

      # After 1 second, refill should add tokens
      {allowed, _tokens} = RateLimiter.check_client_limit(table, "c1", config, now + 1000)
      assert allowed
    end
  end

  describe "cleanup_expired_buckets/3" do
    setup do
      table = :ets.new(:test_cleanup, [:public])
      %{table: table}
    end

    test "removes expired buckets", %{table: table} do
      now = System.monotonic_time(:millisecond)
      :ets.insert(table, {"old", 5, now - 400_000})
      :ets.insert(table, {"new", 5, now})

      RateLimiter.cleanup_expired_buckets(table, [:test, :rate], 300_000)

      assert :ets.lookup(table, "old") == []
      assert :ets.lookup(table, "new") != []
    end

    test "keeps all buckets when none expired", %{table: table} do
      now = System.monotonic_time(:millisecond)
      :ets.insert(table, {"a", 5, now})
      :ets.insert(table, {"b", 5, now})

      RateLimiter.cleanup_expired_buckets(table, [:test, :rate], 300_000)

      assert :ets.info(table, :size) == 2
    end
  end
end
