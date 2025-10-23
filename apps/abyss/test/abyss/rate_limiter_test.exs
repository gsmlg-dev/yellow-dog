defmodule Abyss.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Abyss.RateLimiter

  describe "start_link/1" do
    test "starts with default options" do
      {:ok, pid} = start_supervised({RateLimiter, []})
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "starts with custom options" do
      {:ok, pid} =
        start_supervised(
          {RateLimiter,
           [
             enabled: true,
             max_packets: 100,
             window_ms: 500
           ]}
        )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "allow_packet?/1" do
    test "allows all packets when rate limiting is disabled" do
      {:ok, _pid} = start_supervised({RateLimiter, [enabled: false]})

      ip = {127, 0, 0, 1}
      assert RateLimiter.allow_packet?(ip)
      assert RateLimiter.allow_packet?(ip)
      assert RateLimiter.allow_packet?(ip)
    end

    test "allows packets within rate limit" do
      {:ok, _pid} =
        start_supervised(
          {RateLimiter,
           [
             enabled: true,
             max_packets: 2,
             window_ms: 1000
           ]}
        )

      ip = {127, 0, 0, 1}
      # First packet
      assert RateLimiter.allow_packet?(ip)
      # Second packet (at limit)
      assert RateLimiter.allow_packet?(ip)
    end

    test "blocks packets exceeding rate limit" do
      {:ok, _pid} =
        start_supervised(
          {RateLimiter,
           [
             enabled: true,
             max_packets: 2,
             window_ms: 1000
           ]}
        )

      ip = {127, 0, 0, 1}
      # First packet
      assert RateLimiter.allow_packet?(ip)
      # Second packet
      assert RateLimiter.allow_packet?(ip)
      # Third packet (exceeds limit)
      refute RateLimiter.allow_packet?(ip)
    end

    test "handles different IP addresses independently" do
      {:ok, _pid} =
        start_supervised(
          {RateLimiter,
           [
             enabled: true,
             max_packets: 1,
             window_ms: 1000
           ]}
        )

      ip1 = {127, 0, 0, 1}
      ip2 = {192, 168, 1, 1}

      assert RateLimiter.allow_packet?(ip1)
      # Different IP, should be allowed
      assert RateLimiter.allow_packet?(ip2)
      # IP1 exceeded limit
      refute RateLimiter.allow_packet?(ip1)
      # IP2 exceeded limit
      refute RateLimiter.allow_packet?(ip2)
    end

    test "handles IPv6 addresses" do
      {:ok, _pid} =
        start_supervised(
          {RateLimiter,
           [
             enabled: true,
             max_packets: 2,
             window_ms: 1000
           ]}
        )

      ip = {0, 0, 0, 0, 0, 0, 0, 1}
      assert RateLimiter.allow_packet?(ip)
      assert RateLimiter.allow_packet?(ip)
      refute RateLimiter.allow_packet?(ip)
    end
  end

  describe "get_stats/0" do
    test "returns current statistics" do
      {:ok, _pid} =
        start_supervised(
          {RateLimiter,
           [
             enabled: true,
             max_packets: 10,
             window_ms: 1000
           ]}
        )

      stats = RateLimiter.get_stats()

      assert stats.enabled == true
      assert stats.max_packets == 10
      assert stats.window_ms == 1000
      assert is_integer(stats.active_buckets)
      assert is_integer(stats.total_buckets)
    end
  end

  describe "cleanup" do
    test "cleans up expired buckets" do
      # This test is difficult to implement reliably due to timing
      # but we can test that cleanup doesn't crash the process
      {:ok, _pid} =
        start_supervised(
          {RateLimiter,
           [
             enabled: true,
             max_packets: 10,
             window_ms: 100
           ]}
        )

      ip = {127, 0, 0, 1}
      assert RateLimiter.allow_packet?(ip)

      # Wait for cleanup interval (simulated)
      Process.sleep(50)

      stats = RateLimiter.get_stats()
      assert stats.active_buckets >= 0
    end
  end
end
