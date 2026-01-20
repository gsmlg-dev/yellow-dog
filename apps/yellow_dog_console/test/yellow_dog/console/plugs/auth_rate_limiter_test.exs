defmodule YellowDog.Console.Plugs.AuthRateLimiterTest do
  use ExUnit.Case, async: false

  alias YellowDog.Console.Plugs.AuthRateLimiter

  setup do
    # The rate limiter is started by the application supervisor
    # Clear any existing entries before each test
    try do
      :ets.delete_all_objects(:auth_rate_limiter)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  describe "check_rate_limit/1" do
    test "allows first attempt from new IP" do
      assert {:ok, 5} = AuthRateLimiter.check_rate_limit("192.168.1.100")
    end

    test "returns decreasing attempts remaining" do
      ip = "192.168.1.101"
      assert {:ok, 5} = AuthRateLimiter.check_rate_limit(ip)

      AuthRateLimiter.record_failure(ip)
      assert {:ok, 4} = AuthRateLimiter.check_rate_limit(ip)

      AuthRateLimiter.record_failure(ip)
      assert {:ok, 3} = AuthRateLimiter.check_rate_limit(ip)
    end

    test "returns locked_out after max attempts" do
      ip = "192.168.1.102"

      # Exhaust all attempts
      for _ <- 1..5 do
        AuthRateLimiter.record_failure(ip)
      end

      assert {:error, :locked_out, seconds} = AuthRateLimiter.check_rate_limit(ip)
      assert seconds > 0
      assert seconds <= 300
    end
  end

  describe "record_failure/1" do
    test "increments failure count" do
      ip = "192.168.1.103"

      AuthRateLimiter.record_failure(ip)
      assert {:ok, 4} = AuthRateLimiter.check_rate_limit(ip)

      AuthRateLimiter.record_failure(ip)
      assert {:ok, 3} = AuthRateLimiter.check_rate_limit(ip)
    end

    @tag :capture_log
    test "triggers lockout after max attempts" do
      ip = "192.168.1.104"

      # 5 failures should trigger lockout
      for _ <- 1..5 do
        AuthRateLimiter.record_failure(ip)
      end

      assert {:error, :locked_out, _seconds} = AuthRateLimiter.check_rate_limit(ip)
    end

    test "does not increment during lockout" do
      ip = "192.168.1.105"

      # Trigger lockout
      for _ <- 1..5 do
        AuthRateLimiter.record_failure(ip)
      end

      {:error, :locked_out, seconds1} = AuthRateLimiter.check_rate_limit(ip)

      # Additional failure during lockout
      AuthRateLimiter.record_failure(ip)

      {:error, :locked_out, seconds2} = AuthRateLimiter.check_rate_limit(ip)

      # Lockout time should not increase
      assert seconds2 <= seconds1
    end
  end

  describe "record_success/1" do
    test "clears failure count after successful auth" do
      ip = "192.168.1.106"

      # Record some failures
      AuthRateLimiter.record_failure(ip)
      AuthRateLimiter.record_failure(ip)
      assert {:ok, 3} = AuthRateLimiter.check_rate_limit(ip)

      # Successful auth should reset
      AuthRateLimiter.record_success(ip)
      assert {:ok, 5} = AuthRateLimiter.check_rate_limit(ip)
    end

    test "handles clearing non-existent entry" do
      # Should not raise
      assert :ok = AuthRateLimiter.record_success("192.168.1.107")
    end
  end

  describe "stats/0" do
    test "returns statistics" do
      stats = AuthRateLimiter.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_entries)
      assert Map.has_key?(stats, :locked_out_ips)
      assert Map.has_key?(stats, :max_attempts)
      assert Map.has_key?(stats, :lockout_seconds)
    end

    @tag :capture_log
    test "counts locked out IPs" do
      # Clear existing entries
      :ets.delete_all_objects(:auth_rate_limiter)

      ip1 = "192.168.1.108"
      ip2 = "192.168.1.109"

      # Lock out ip1
      for _ <- 1..5 do
        AuthRateLimiter.record_failure(ip1)
      end

      # Partially fail ip2
      AuthRateLimiter.record_failure(ip2)
      AuthRateLimiter.record_failure(ip2)

      stats = AuthRateLimiter.stats()
      assert stats.total_entries == 2
      assert stats.locked_out_ips == 1
    end
  end

  describe "graceful handling" do
    test "handles ETS table not existing" do
      # If the table doesn't exist, functions should return safe defaults
      # This is tested via the rescue clauses in the module

      # The table exists due to application startup, but we can verify
      # the return types are correct
      assert {:ok, _} = AuthRateLimiter.check_rate_limit("test")
      assert :ok = AuthRateLimiter.record_failure("test")
      assert :ok = AuthRateLimiter.record_success("test")
    end
  end

  describe "different IP addresses" do
    test "tracks IPs independently" do
      ip1 = "192.168.1.110"
      ip2 = "192.168.1.111"

      # Fail ip1 multiple times
      for _ <- 1..4 do
        AuthRateLimiter.record_failure(ip1)
      end

      # ip2 should still have full attempts
      assert {:ok, 5} = AuthRateLimiter.check_rate_limit(ip2)
      assert {:ok, 1} = AuthRateLimiter.check_rate_limit(ip1)
    end
  end
end
