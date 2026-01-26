defmodule YellowDog.Dns.RateLimiterTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.RateLimiter

  setup do
    # Start rate limiter with known configuration for testing
    config = [
      enabled: true,
      client_tokens: 10,
      client_refill_rate: 20,
      global_tokens: 200,
      global_refill_rate: 100,
      bucket_ttl: 5_000,
      cleanup_interval: 1_000
    ]

    # Stop any existing rate limiter
    case GenServer.whereis(RateLimiter) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    # Give ETS table time to clean up
    Process.sleep(10)

    {:ok, pid} = RateLimiter.start_link(config)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    {:ok, pid: pid}
  end

  describe "check_rate/1" do
    test "allows requests within rate limit" do
      client_ip = {192, 168, 1, 100}

      # First request should be allowed
      assert :ok = RateLimiter.check_rate(client_ip)
    end

    test "allows burst up to token limit" do
      client_ip = {192, 168, 1, 101}

      # Should allow up to 10 requests (client_tokens)
      for _ <- 1..10 do
        assert :ok = RateLimiter.check_rate(client_ip)
      end
    end

    test "denies requests when client tokens exhausted" do
      client_ip = {192, 168, 1, 102}

      # Exhaust all tokens
      for _ <- 1..10 do
        RateLimiter.check_rate(client_ip)
      end

      # Next request should be denied
      assert {:error, :rate_limited} = RateLimiter.check_rate(client_ip)
    end

    test "allows requests from different clients independently" do
      client1 = {192, 168, 1, 103}
      client2 = {192, 168, 1, 104}

      # Exhaust client1's tokens
      for _ <- 1..10 do
        RateLimiter.check_rate(client1)
      end

      # Client2 should still be allowed
      assert :ok = RateLimiter.check_rate(client2)
    end

    test "refills tokens over time" do
      client_ip = {192, 168, 1, 105}

      # Exhaust all tokens
      for _ <- 1..10 do
        RateLimiter.check_rate(client_ip)
      end

      # Should be denied immediately
      assert {:error, :rate_limited} = RateLimiter.check_rate(client_ip)

      # Wait for refill (100ms should give us 2 tokens at 20/sec rate)
      Process.sleep(150)

      # Should be allowed after refill
      assert :ok = RateLimiter.check_rate(client_ip)
    end

    test "handles binary client identifiers" do
      client_id = <<192, 168, 1, 1>>

      assert :ok = RateLimiter.check_rate(client_id)
    end

    test "handles IPv4 tuple client identifiers" do
      ip = {10, 0, 0, 1}

      assert :ok = RateLimiter.check_rate(ip)
    end

    test "handles IPv6 tuple client identifiers" do
      ip = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}

      assert :ok = RateLimiter.check_rate(ip)
    end
  end

  describe "global rate limiting" do
    test "enforces global token limit" do
      # Each request from different clients consumes global tokens
      # With global_tokens: 200, we should be able to make many requests
      for i <- 1..150 do
        client_ip = {10, 0, div(i, 256), rem(i, 256)}
        assert :ok = RateLimiter.check_rate(client_ip)
      end

      stats = RateLimiter.stats()
      assert stats.total_allowed >= 150
    end
  end

  describe "stats/0" do
    test "returns rate limiter statistics" do
      client_ip = {192, 168, 1, 200}

      # Make some requests
      RateLimiter.check_rate(client_ip)
      RateLimiter.check_rate(client_ip)

      stats = RateLimiter.stats()

      assert stats.enabled == true
      assert stats.total_allowed >= 2
      assert stats.active_buckets >= 1
      assert is_map(stats.config)
    end
  end

  describe "reset/0" do
    test "clears all rate limit buckets" do
      client_ip = {192, 168, 1, 201}

      # Exhaust tokens
      for _ <- 1..10 do
        RateLimiter.check_rate(client_ip)
      end

      assert {:error, :rate_limited} = RateLimiter.check_rate(client_ip)

      # Reset
      :ok = RateLimiter.reset()

      # Should be allowed after reset
      assert :ok = RateLimiter.check_rate(client_ip)
    end

    test "resets statistics" do
      client_ip = {192, 168, 1, 202}

      # Make some requests
      RateLimiter.check_rate(client_ip)
      RateLimiter.check_rate(client_ip)

      stats_before = RateLimiter.stats()
      assert stats_before.total_allowed >= 2

      # Reset
      :ok = RateLimiter.reset()

      stats_after = RateLimiter.stats()
      assert stats_after.total_allowed == 0
      assert stats_after.total_denied == 0
    end
  end

  describe "enabled?/0" do
    test "returns true when enabled" do
      assert RateLimiter.enabled?() == true
    end
  end

  describe "disabled rate limiter" do
    test "allows all requests when disabled" do
      # Stop current limiter
      GenServer.stop(RateLimiter, :normal)
      Process.sleep(10)

      # Start with disabled
      {:ok, pid} = RateLimiter.start_link(enabled: false)

      on_exit(fn ->
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal)
        end
      end)

      client_ip = {192, 168, 1, 203}

      # Should allow unlimited requests
      for _ <- 1..100 do
        assert :ok = RateLimiter.check_rate(client_ip)
      end

      assert RateLimiter.enabled?() == false
    end
  end

  describe "graceful handling when not running" do
    test "check_rate returns :ok when rate limiter not running" do
      # Stop rate limiter
      GenServer.stop(RateLimiter, :normal)
      Process.sleep(10)

      # Should not crash, just allow
      assert :ok = RateLimiter.check_rate({192, 168, 1, 204})
    end

    test "stats returns error when not running" do
      GenServer.stop(RateLimiter, :normal)
      Process.sleep(10)

      assert %{error: :not_running} = RateLimiter.stats()
    end

    test "enabled? returns false when not running" do
      GenServer.stop(RateLimiter, :normal)
      Process.sleep(10)

      assert RateLimiter.enabled?() == false
    end
  end
end
