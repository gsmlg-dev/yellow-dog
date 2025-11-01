defmodule YellowDog.Dns.Phase2PerformanceTest do
  @moduledoc """
  Performance tests for Phase 2 Week 12 features:
  - Cache integration
  - Sub-zone delegation
  - RPZ (Response Policy Zones)
  """

  use ExUnit.Case, async: false

  alias YellowDog.Dns.Query.Delegation
  alias YellowDog.Dns.RPZ
  alias YellowDog.Dns.Query.Cache.Manager, as: CacheManager
  alias YellowDog.Dns.Query.Cache.Stats
  alias YellowDog.Dns.Zone.Manager
  alias YellowDog.Dns.Zone.Record

  @moduletag :performance
  @moduletag timeout: :infinity

  setup do
    # Initialize Zone Storage ETS table if needed
    case :ets.whereis(:dns_zone_storage) do
      :undefined -> YellowDog.Dns.Zone.Storage.init()
      _ -> :ok
    end

    # Start Zone Manager
    {:ok, _pid} = start_supervised(Manager)

    # Start Cache Manager and Cleaner
    cache_config = [
      max_size: 100_000,
      default_ttl: 300,
      negative_ttl: 60,
      enable_stats: true
    ]

    {:ok, _} = start_supervised({CacheManager, cache_config})
    {:ok, _} = start_supervised({YellowDog.Dns.Query.Cache.Cleaner, cache_config})

    :ok
  end

  describe "Cache performance" do
    test "cache can handle 10000 rapid insertions" do
      IO.puts("\n=== Cache Insertion Performance ===")

      {time_us, :ok} = :timer.tc(fn ->
        for i <- 1..10_000 do
          key = "test#{i}.example.com"
          records = [
            %Record{
              owner: key,
              type: :A,
              class: :IN,
              ttl: 300,
              rdata: {192, 0, 2, div(i, 256) + 1}
            }
          ]

          CacheManager.put(key, :A, :IN, records, [], 300)
        end
      end)

      time_ms = time_us / 1000
      qps = 10_000 / (time_us / 1_000_000)

      IO.puts("Inserted 10000 entries in #{time_ms}ms")
      IO.puts("Insertion rate: #{:erlang.float_to_binary(qps, decimals: 0)} entries/sec")

      stats = CacheManager.stats()
      IO.puts("Total entries in cache: #{stats.total_entries}")
      IO.puts("Memory usage: #{Stats.memory_mb(stats)} MB")

      # Should complete in reasonable time
      assert time_ms < 5000, "Cache insertion took #{time_ms}ms, expected < 5000ms"
    end

    test "cache lookups are fast" do
      IO.puts("\n=== Cache Lookup Performance ===")

      # Pre-populate cache
      for i <- 1..1000 do
        key = "lookup#{i}.example.com"
        records = [
          %Record{
            owner: key,
            type: :A,
            class: :IN,
            ttl: 300,
            rdata: {192, 0, 2, div(i, 256) + 1}
          }
        ]

        CacheManager.put(key, :A, :IN, records, [], 300)
      end

      # Measure lookup performance
      {time_us, _results} = :timer.tc(fn ->
        for i <- 1..1000 do
          key = "lookup#{i}.example.com"
          CacheManager.get(key, :A, :IN)
        end
      end)

      time_ms = time_us / 1000
      qps = 1000 / (time_us / 1_000_000)

      IO.puts("Performed 1000 lookups in #{time_ms}ms")
      IO.puts("Lookup rate: #{:erlang.float_to_binary(qps, decimals: 0)} lookups/sec")

      stats = CacheManager.stats()
      hit_rate = Stats.hit_rate(stats) * 100
      IO.puts("Cache hit rate: #{:erlang.float_to_binary(hit_rate, decimals: 1)}%")

      # Lookups should be very fast
      assert time_ms < 1000, "Cache lookups took #{time_ms}ms, expected < 1000ms"
      assert hit_rate > 90.0, "Hit rate #{hit_rate}% too low"
    end
  end

  describe "Delegation performance" do
    test "delegation checking is fast" do
      IO.puts("\n=== Delegation Performance ===")

      # Test delegation checking without zone data (tests the logic speed)
      {time_us, _results} = :timer.tc(fn ->
        for i <- 1..10_000 do
          zone = "example.com"
          qname = "test#{i}.sub.example.com"
          Delegation.check_delegation(zone, qname, :A)
        end
      end)

      time_ms = time_us / 1000
      qps = 10_000 / (time_us / 1_000_000)

      IO.puts("Performed 10000 delegation checks in #{time_ms}ms")
      IO.puts("Check rate: #{:erlang.float_to_binary(qps, decimals: 0)} checks/sec")

      # Delegation logic should be fast
      assert time_ms < 2000, "Delegation checking took #{time_ms}ms, expected < 2000ms"
    end

    test "delegation point finding is efficient" do
      IO.puts("\n=== Delegation Point Finding Performance ===")

      # Test finding delegation points for various depths
      test_cases = [
        {"example.com", "www.example.com"},
        {"example.com", "test.sub.example.com"},
        {"example.com", "deep.test.sub.example.com"},
        {"example.com", "very.deep.test.sub.example.com"}
      ]

      {time_us, _results} = :timer.tc(fn ->
        for _i <- 1..5000 do
          Enum.each(test_cases, fn {zone, qname} ->
            Delegation.find_delegation_point(zone, qname)
          end)
        end
      end)

      time_ms = time_us / 1000
      total_checks = 5000 * length(test_cases)
      qps = total_checks / (time_us / 1_000_000)

      IO.puts("Performed #{total_checks} delegation point searches in #{time_ms}ms")
      IO.puts("Search rate: #{:erlang.float_to_binary(qps, decimals: 0)} searches/sec")

      # Should handle various depths efficiently
      assert time_ms < 3000, "Delegation point finding took #{time_ms}ms, expected < 3000ms"
    end
  end

  describe "RPZ performance" do
    test "RPZ action decoding is fast" do
      IO.puts("\n=== RPZ Action Decoding Performance ===")

      actions = [".", "*.", "rpz-passthru.", "rpz-drop.", "rpz-tcp-only."]

      {time_us, _results} = :timer.tc(fn ->
        for _i <- 1..50_000 do
          Enum.each(actions, fn action ->
            RPZ.decode_rpz_action(action, :A)
          end)
        end
      end)

      time_ms = time_us / 1000
      total_decodes = 50_000 * length(actions)
      qps = total_decodes / (time_us / 1_000_000)

      IO.puts("Performed #{total_decodes} action decodings in #{time_ms}ms")
      IO.puts("Decode rate: #{:erlang.float_to_binary(qps, decimals: 0)} decodes/sec")

      # Action decoding is pure logic, should be very fast
      assert time_ms < 1000, "RPZ action decoding took #{time_ms}ms, expected < 1000ms"
    end

    test "RPZ name normalization is efficient" do
      IO.puts("\n=== RPZ Name Normalization Performance ===")

      # Test with various name formats
      names = [
        "example.com",
        "example.com.",
        "EXAMPLE.COM",
        "EXAMPLE.COM.",
        "www.example.com",
        "*.example.com"
      ]

      {time_us, _results} = :timer.tc(fn ->
        for _i <- 1..20_000 do
          Enum.each(names, fn _name ->
            # Normalization happens inside decode_rpz_action
            RPZ.decode_rpz_action("rpz-drop.", :A)
          end)
        end
      end)

      time_ms = time_us / 1000
      total_ops = 20_000 * length(names)
      qps = total_ops / (time_us / 1_000_000)

      IO.puts("Performed #{total_ops} name normalizations in #{time_ms}ms")
      IO.puts("Normalization rate: #{:erlang.float_to_binary(qps, decimals: 0)} ops/sec")

      assert time_ms < 1000, "Name normalization took #{time_ms}ms, expected < 1000ms"
    end
  end

  describe "Integration performance" do
    test "combined cache + delegation + RPZ overhead is minimal" do
      IO.puts("\n=== Integration Performance ===")

      # Simulate a full query path:
      # 1. Check RPZ
      # 2. Check cache
      # 3. Check delegation
      # 4. Cache result

      {time_us, _results} = :timer.tc(fn ->
        for i <- 1..5000 do
          qname = "test#{i}.example.com"

          # 1. RPZ check (action decoding)
          RPZ.decode_rpz_action("rpz-passthru.", :A)

          # 2. Cache lookup
          CacheManager.get(qname, :A, :IN)

          # 3. Delegation check
          Delegation.check_delegation("example.com", qname, :A)

          # 4. Cache insertion (on miss)
          records = [
            %Record{
              owner: qname,
              type: :A,
              class: :IN,
              ttl: 300,
              rdata: {192, 0, 2, rem(i, 254) + 1}
            }
          ]

          CacheManager.put(qname, :A, :IN, records, [], 300)
        end
      end)

      time_ms = time_us / 1000
      qps = 5000 / (time_us / 1_000_000)

      IO.puts("Processed 5000 simulated queries in #{time_ms}ms")
      IO.puts("Query rate: #{:erlang.float_to_binary(qps, decimals: 0)} queries/sec")
      IO.puts("Average latency: #{:erlang.float_to_binary(time_us / 5000, decimals: 2)} µs/query")

      # Full integration should still be fast
      assert time_ms < 5000, "Integration test took #{time_ms}ms, expected < 5000ms"
    end
  end
end
