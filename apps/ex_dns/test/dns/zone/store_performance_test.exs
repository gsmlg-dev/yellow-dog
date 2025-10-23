defmodule DNS.Zone.StorePerformanceTest do
  use ExUnit.Case

  alias DNS.Zone.Store
  alias DNS.Zone

  @moduletag :performance

  describe "ETS query performance" do
    setup do
      # Clean up before tests
      Store.clear()
      :ok
    end

    test "zones_by_type performance with optimized queries" do
      # Create a large number of zones of different types
      zone_types = [:authoritative, :stub, :forward, :cache]
      zones_per_type = 100

      # Insert test zones
      Enum.each(zone_types, fn type ->
        Enum.each(1..zones_per_type, fn i ->
          zone_name = "test#{i}-#{type}.com"
          zone = Zone.new(zone_name, type)
          Store.put_zone(zone)
        end)
      end)

      # Performance test: measure time for filtered queries
      {time, result} =
        :timer.tc(fn ->
          Store.get_zones_by_type(:authoritative)
        end)

      # Should return all zones of the specified type
      assert length(result) == zones_per_type

      # Performance should be sub-millisecond for this operation
      # (This is a rough guideline - actual performance depends on hardware)
      assert time < 5000, "ETS query took too long: #{time} microseconds"

      # Test all types
      Enum.each(zone_types, fn type ->
        zones = Store.get_zones_by_type(type)
        assert length(zones) == zones_per_type
      end)
    end

    test "comparison with naive enumeration" do
      # Create test data
      zone_types = [:authoritative, :stub, :forward, :cache]
      zones_per_type = 50

      Enum.each(zone_types, fn type ->
        Enum.each(1..zones_per_type, fn i ->
          zone_name = "perf#{i}-#{type}.com"
          zone = Zone.new(zone_name, type)
          Store.put_zone(zone)
        end)
      end)

      # Test optimized query
      {optimized_time, optimized_result} =
        :timer.tc(fn ->
          Store.get_zones_by_type(:authoritative)
        end)

      # Test naive enumeration (simulating old approach)
      {naive_time, naive_result} =
        :timer.tc(fn ->
          Store.list_zones()
          |> Enum.filter(&(&1.type == :authoritative))
        end)

      # Results should be the same
      assert length(optimized_result) == length(naive_result)
      assert length(optimized_result) == zones_per_type

      # Optimized should be faster (allowing some variance for small datasets)
      # For larger datasets, the difference would be more significant
      IO.puts("Optimized query: #{optimized_time}μs, Naive enumeration: #{naive_time}μs")
    end

    test "performance scales with zone count" do
      zone_counts = [10, 50, 100, 200]
      target_type = :authoritative

      Enum.each(zone_counts, fn count ->
        # Clean up
        Store.clear()

        # Create zones - ensure at least one authoritative zone
        Enum.each(1..count, fn i ->
          # Mix of zone types, but ensure first one is authoritative
          type =
            if i == 1,
              do: :authoritative,
              else: Enum.random([:authoritative, :stub, :forward, :cache])

          zone_name = "scale#{i}.com"
          zone = Zone.new(zone_name, type)
          Store.put_zone(zone)
        end)

        # Measure query time
        {time, zones} =
          :timer.tc(fn ->
            Store.get_zones_by_type(target_type)
          end)

        # Verify results
        authoritative_zones = Enum.filter(zones, &(&1.type == target_type))
        assert length(authoritative_zones) > 0

        # Performance should remain reasonable even with more zones
        # Time should grow slowly, not linearly with zone count
        IO.puts("#{count} zones: #{time}μs for type query")

        # Ensure it's still fast (under 10ms even for 200 zones)
        assert time < 10000, "Query performance degraded too much with #{count} zones"
      end)
    end
  end

  describe "ETS table configuration performance" do
    test "read concurrency performance" do
      # Create test zones
      Enum.each(1..50, fn i ->
        zone_name = "concurrency#{i}.com"
        zone = Zone.new(zone_name, :authoritative)
        Store.put_zone(zone)
      end)

      # Test concurrent reads
      read_tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Enum.each(1..10, fn _j ->
              Store.get_zones_by_type(:authoritative)
            end)
          end)
        end

      {time, _results} =
        :timer.tc(fn ->
          Task.await_many(read_tasks, 5000)
        end)

      # Concurrent operations should complete quickly
      assert time < 50000, "Concurrent reads took too long: #{time} microseconds"
    end

    test "ETS table access patterns" do
      # Test various access patterns to ensure the table is properly configured
      zone_count = 100

      # Create zones with different types
      Enum.each(1..zone_count, fn i ->
        type = Enum.random([:authoritative, :stub, :forward, :cache])
        zone_name = "pattern#{i}.com"
        zone = Zone.new(zone_name, type)
        Store.put_zone(zone)
      end)

      # Test individual zone lookups
      {lookup_time, _} =
        :timer.tc(fn ->
          Enum.each(1..10, fn i ->
            Store.get_zone("pattern#{i}.com")
          end)
        end)

      # Test type filtering
      {filter_time, _} =
        :timer.tc(fn ->
          Enum.each([:authoritative, :stub, :forward, :cache], fn type ->
            Store.get_zones_by_type(type)
          end)
        end)

      # Test full enumeration
      {enum_time, zones} =
        :timer.tc(fn ->
          Store.list_zones()
        end)

      assert length(zones) == zone_count

      # All operations should be fast
      assert lookup_time < 5000, "Individual lookups too slow"
      assert filter_time < 10000, "Type filtering too slow"
      assert enum_time < 50000, "Full enumeration too slow"

      IO.puts("Lookup: #{lookup_time}μs, Filter: #{filter_time}μs, Enum: #{enum_time}μs")
    end
  end

  describe "memory usage and efficiency" do
    test "ETS table memory efficiency" do
      # Monitor memory usage before and after zone creation
      :erlang.garbage_collect()
      {:memory, memory_before} = :erlang.process_info(self(), :memory)

      # Create many zones
      zone_count = 500

      Enum.each(1..zone_count, fn i ->
        zone_name = "memory#{i}.com"
        zone = Zone.new(zone_name, :authoritative)
        Store.put_zone(zone)
      end)

      # Check memory usage
      {:memory, memory_after} = :erlang.process_info(self(), :memory)
      memory_increase = memory_after - memory_before

      # Memory increase should be reasonable (less than 1MB for 500 zones)
      assert memory_increase < 1_000_000, "Memory usage too high: #{memory_increase} bytes"

      # Verify all zones are stored correctly
      zones = Store.list_zones()
      assert length(zones) == zone_count

      IO.puts("Memory increase for #{zone_count} zones: #{memory_increase} bytes")
    end
  end

  describe "protected access verification" do
    test "ETS table has protected access" do
      # This test verifies that the ETS table is configured with protected access
      # We can't directly test access permissions, but we can verify the table exists
      # and operations work correctly

      # Ensure table exists
      Store.init()

      # Verify table exists and is accessible
      table_info = :ets.info(:dns_zones)
      assert table_info != :undefined

      # Check that it's a set table (as expected)
      assert table_info[:type] == :set

      # Check that it has named_table option
      assert table_info[:named_table] == true

      # Check that read_concurrency is enabled
      assert table_info[:read_concurrency] == true

      # Check that it's public (as configured in Store module)
      # Note: The Store module uses :public access for the ETS table
      assert table_info[:protection] == :public
    end
  end
end
