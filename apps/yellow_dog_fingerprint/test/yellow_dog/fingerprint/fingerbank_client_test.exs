defmodule YellowDog.Fingerprint.FingerbankClientTest do
  @moduledoc """
  Tests for FingerbankClient GenServer — cache, rate limiting, and API stub.

  Uses a unique-named process per test to avoid ETS table conflicts.
  """
  use ExUnit.Case, async: false

  alias YellowDog.Fingerprint.FingerbankClient

  # ── Module structure ──────────────────────────────────────────────

  describe "module structure" do
    test "module is loadable" do
      assert {:module, FingerbankClient} = Code.ensure_loaded(FingerbankClient)
    end

    test "exports start_link/1" do
      Code.ensure_loaded!(FingerbankClient)
      assert function_exported?(FingerbankClient, :start_link, 1)
    end

    test "exports interrogate/1" do
      Code.ensure_loaded!(FingerbankClient)
      assert function_exported?(FingerbankClient, :interrogate, 1)
    end

    test "is a GenServer" do
      behaviours =
        FingerbankClient.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert GenServer in behaviours
    end
  end

  # ── GenServer lifecycle ───────────────────────────────────────────

  describe "init/1" do
    test "starts and creates ETS cache table" do
      # If already exists from another test, delete it first
      if :ets.info(:fp_fingerbank_cache) != :undefined do
        :ets.delete(:fp_fingerbank_cache)
      end

      pid = start_supervised!({FingerbankClient, []})
      assert Process.alive?(pid)

      # ETS table should exist
      assert :ets.info(:fp_fingerbank_cache) != :undefined
    end

    test "initial state has zero requests_this_hour" do
      if :ets.info(:fp_fingerbank_cache) != :undefined do
        :ets.delete(:fp_fingerbank_cache)
      end

      pid = start_supervised!({FingerbankClient, []})

      # Use sys to inspect state
      state = :sys.get_state(pid)
      assert state.requests_this_hour == 0
    end

    test "initial state reads config from application env" do
      if :ets.info(:fp_fingerbank_cache) != :undefined do
        :ets.delete(:fp_fingerbank_cache)
      end

      pid = start_supervised!({FingerbankClient, []})
      state = :sys.get_state(pid)

      assert is_binary(state.api_key)
      assert is_binary(state.base_url)
      assert is_integer(state.ttl_hours)
      assert is_integer(state.rate_limit)
    end
  end

  # ── Interrogate (stub behavior) ──────────────────────────────────

  describe "interrogate/1" do
    setup do
      if :ets.info(:fp_fingerbank_cache) != :undefined do
        :ets.delete(:fp_fingerbank_cache)
      end

      pid = start_supervised!({FingerbankClient, []})
      {:ok, pid: pid}
    end

    test "returns error with no API key (default config)" do
      fingerprint = %{id: "test-fp-1", dhcp_fingerprint: "1,3,6,15"}
      assert {:error, reason} = FingerbankClient.interrogate(fingerprint)
      assert reason in [:no_api_key, :not_implemented]
    end

    test "caches results for subsequent calls" do
      fingerprint = %{id: "test-fp-cache", dhcp_fingerprint: "1,3,6,15"}

      result1 = FingerbankClient.interrogate(fingerprint)
      result2 = FingerbankClient.interrogate(fingerprint)

      # Both calls return the same result (second from cache)
      assert result1 == result2
    end

    test "increments request counter on cache miss" do
      fingerprint = %{id: "test-fp-counter", dhcp_fingerprint: "1,3,6,15"}

      FingerbankClient.interrogate(fingerprint)

      state = :sys.get_state(Process.whereis(FingerbankClient))
      assert state.requests_this_hour == 1
    end

    test "does not increment counter on cache hit" do
      fingerprint = %{id: "test-fp-hit", dhcp_fingerprint: "1,3,6,15"}

      # First call: cache miss, counter increments
      FingerbankClient.interrogate(fingerprint)
      # Second call: cache hit, counter stays
      FingerbankClient.interrogate(fingerprint)

      state = :sys.get_state(Process.whereis(FingerbankClient))
      assert state.requests_this_hour == 1
    end
  end

  # ── Rate limiting ────────────────────────────────────────────────

  describe "rate limiting" do
    setup do
      if :ets.info(:fp_fingerbank_cache) != :undefined do
        :ets.delete(:fp_fingerbank_cache)
      end

      # Start with a very low rate limit for testing
      Application.put_env(:yellow_dog_fingerprint, :fingerbank_rate_limit, 2)

      on_exit(fn ->
        Application.delete_env(:yellow_dog_fingerprint, :fingerbank_rate_limit)
      end)

      pid = start_supervised!({FingerbankClient, []})
      {:ok, pid: pid}
    end

    test "returns rate_limited when limit exceeded" do
      # Make 2 unique requests to hit the limit
      FingerbankClient.interrogate(%{id: "rate-1", dhcp_fingerprint: "1"})
      FingerbankClient.interrogate(%{id: "rate-2", dhcp_fingerprint: "2"})

      # Third request should be rate limited
      assert {:error, :rate_limited} =
               FingerbankClient.interrogate(%{id: "rate-3", dhcp_fingerprint: "3"})
    end
  end
end
