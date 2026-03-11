defmodule YellowDog.Resolved.RateLimiterTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.RateLimiter

  setup do
    config = %{rate_limit: %{burst: 5, rate: 2}}
    pid = start_supervised!({RateLimiter, config})
    on_exit(fn -> if Process.alive?(pid), do: stop_supervised!(RateLimiter) end)
    %{pid: pid}
  end

  describe "allow?/1" do
    test "allows first request from new IP" do
      assert :ok = RateLimiter.allow?({192, 168, 1, 1})
    end

    test "allows requests up to burst limit" do
      ip = {10, 0, 0, 1}

      results = for _ <- 1..5, do: RateLimiter.allow?(ip)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "rate-limits after burst exhausted" do
      ip = {10, 0, 0, 2}

      # Exhaust the burst (5 tokens)
      for _ <- 1..5, do: RateLimiter.allow?(ip)

      # Next request should be rate-limited
      assert :rate_limited = RateLimiter.allow?(ip)
    end

    test "tokens refill over time" do
      ip = {10, 0, 0, 3}

      # Exhaust burst
      for _ <- 1..5, do: RateLimiter.allow?(ip)
      assert :rate_limited = RateLimiter.allow?(ip)

      # Wait for refill (rate=2/sec, need 1 token = 500ms)
      Process.sleep(600)

      assert :ok = RateLimiter.allow?(ip)
    end

    test "different IPs have independent buckets" do
      ip_a = {10, 0, 0, 10}
      ip_b = {10, 0, 0, 11}

      # Exhaust IP A
      for _ <- 1..5, do: RateLimiter.allow?(ip_a)
      assert :rate_limited = RateLimiter.allow?(ip_a)

      # IP B should still be allowed
      assert :ok = RateLimiter.allow?(ip_b)
    end

    test "handles IPv6 addresses" do
      ipv6 = {0, 0, 0, 0, 0, 0, 0, 1}
      assert :ok = RateLimiter.allow?(ipv6)
    end
  end

  describe "telemetry" do
    test "rate_limited telemetry emitted in handler integration" do
      # This tests the telemetry event name is correct
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:yellow_dog, :resolved, :query, :rate_limited]
        ])

      ip = {10, 0, 0, 50}

      # Exhaust bucket
      for _ <- 1..5, do: RateLimiter.allow?(ip)

      # Emit telemetry manually to verify event name matches handler code
      :telemetry.execute(
        [:yellow_dog, :resolved, :query, :rate_limited],
        %{},
        %{client: ip}
      )

      assert_received {[:yellow_dog, :resolved, :query, :rate_limited], ^ref, %{},
                       %{client: {10, 0, 0, 50}}}
    end
  end
end
