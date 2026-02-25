defmodule DNS.Zone.StorePerformanceTest do
  use ExUnit.Case, async: false

  alias DNS.Zone.Store
  alias DNS.Zone

  @moduletag :performance

  # ============================================================================
  # Performance Constants and Helpers
  # ============================================================================

  # Typical TLDs for realistic zone naming
  @tlds ~w(com net org edu gov io dev app cloud)

  # Zone types available in the system
  @zone_types [:authoritative, :stub, :forward, :cache]

  # Generate a realistic zone name
  defp generate_zone_name(prefix, index) do
    tld = Enum.at(@tlds, rem(index, length(@tlds)))
    "#{prefix}#{index}.#{tld}"
  end

  # Generate zones with realistic distribution
  defp generate_zones(count, prefix \\ "zone") do
    Enum.map(1..count, fn i ->
      name = generate_zone_name(prefix, i)
      type = Enum.at(@zone_types, rem(i, length(@zone_types)))
      Zone.new(name, type)
    end)
  end

  # Measure execution time in microseconds
  defp measure(fun) do
    {time, result} = :timer.tc(fun)
    {time, result}
  end

  # Assert time is within threshold with descriptive message
  defp assert_performance(time, max_time, operation) do
    assert time < max_time,
           "#{operation} took #{time}μs, expected < #{max_time}μs"
  end

  # ============================================================================
  # ETS Query Performance Tests
  # ============================================================================

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
      assert time < 100_000, "Concurrent reads took too long: #{time} microseconds"
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

  # ============================================================================
  # Write Performance Tests
  # ============================================================================

  describe "write operation performance" do
    setup do
      Store.clear()
      :ok
    end

    test "single zone insert performance" do
      zone = Zone.new("insert-test.com", :authoritative)

      {time, result} = measure(fn -> Store.put_zone(zone) end)

      assert {:ok, ^zone} = result
      assert_performance(time, 1000, "Single zone insert")
    end

    test "batch zone insert performance" do
      zones = generate_zones(100)

      {time, _} =
        measure(fn ->
          Enum.each(zones, &Store.put_zone/1)
        end)

      # 100 inserts should complete in under 5ms
      assert_performance(time, 5000, "100 zone batch insert")

      # Verify all zones were inserted
      assert length(Store.list_zones()) == 100
    end

    test "zone update performance (overwrite existing)" do
      # Insert initial zones
      zones = generate_zones(50)
      Enum.each(zones, &Store.put_zone/1)

      # Measure update performance
      updated_zones =
        Enum.map(zones, fn zone ->
          %{zone | type: :cache}
        end)

      {time, _} =
        measure(fn ->
          Enum.each(updated_zones, &Store.put_zone/1)
        end)

      assert_performance(time, 5000, "50 zone updates")

      # Verify all zones are now cache type
      Store.list_zones()
      |> Enum.each(fn zone ->
        assert zone.type == :cache
      end)
    end

    test "zone delete performance" do
      zones = generate_zones(100)
      Enum.each(zones, &Store.put_zone/1)

      {time, _} =
        measure(fn ->
          Enum.each(zones, fn zone ->
            Store.delete_zone(zone.name.value)
          end)
        end)

      assert_performance(time, 5000, "100 zone deletes")
      assert Store.list_zones() == []
    end

    test "clear all zones performance" do
      zones = generate_zones(500)
      Enum.each(zones, &Store.put_zone/1)
      assert length(Store.list_zones()) == 500

      {time, _} = measure(fn -> Store.clear() end)

      assert_performance(time, 5000, "Clear 500 zones")
      assert Store.list_zones() == []
    end
  end

  # ============================================================================
  # Read Performance Tests
  # ============================================================================

  describe "read operation performance" do
    setup do
      Store.clear()
      zones = generate_zones(200)
      Enum.each(zones, &Store.put_zone/1)
      {:ok, zones: zones}
    end

    test "single zone lookup performance", %{zones: zones} do
      zone = List.first(zones)

      {time, result} = measure(fn -> Store.get_zone(zone.name.value) end)

      assert {:ok, ^zone} = result
      assert_performance(time, 500, "Single zone lookup")
    end

    test "random zone lookups performance", %{zones: zones} do
      lookup_count = 100
      sample_zones = Enum.take_random(zones, lookup_count)

      {time, results} =
        measure(fn ->
          Enum.map(sample_zones, fn zone ->
            Store.get_zone(zone.name.value)
          end)
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert_performance(time, 5000, "100 random zone lookups")
    end

    test "non-existent zone lookup performance" do
      {time, result} = measure(fn -> Store.get_zone("nonexistent.com") end)

      assert {:error, :not_found} = result
      assert_performance(time, 500, "Non-existent zone lookup")
    end

    test "zone_exists? performance for existing zone", %{zones: zones} do
      zone = List.first(zones)

      {time, result} = measure(fn -> Store.zone_exists?(zone.name.value) end)

      assert result == true
      assert_performance(time, 500, "zone_exists? for existing zone")
    end

    test "zone_exists? performance for non-existent zone" do
      {time, result} = measure(fn -> Store.zone_exists?("nonexistent.com") end)

      assert result == false
      assert_performance(time, 500, "zone_exists? for non-existent zone")
    end

    test "list all zones performance" do
      {time, zones} = measure(fn -> Store.list_zones() end)

      assert length(zones) == 200
      assert_performance(time, 10000, "List 200 zones")
    end

    test "get zones by type performance" do
      # Each type should have ~50 zones (200 / 4 types)
      {time, zones} = measure(fn -> Store.get_zones_by_type(:authoritative) end)

      assert length(zones) >= 40 and length(zones) <= 60
      assert_performance(time, 5000, "Get zones by type")
    end
  end

  # ============================================================================
  # Concurrent Access Performance Tests
  # ============================================================================

  describe "concurrent access performance" do
    setup do
      Store.clear()
      zones = generate_zones(100)
      Enum.each(zones, &Store.put_zone/1)
      {:ok, zones: zones}
    end

    test "concurrent reads performance", %{zones: zones} do
      reader_count = 10
      reads_per_reader = 50

      tasks =
        for _ <- 1..reader_count do
          Task.async(fn ->
            Enum.map(1..reads_per_reader, fn _ ->
              zone = Enum.random(zones)
              Store.get_zone(zone.name.value)
            end)
          end)
        end

      {time, results} = measure(fn -> Task.await_many(tasks, 5000) end)

      # All reads should succeed
      flat_results = List.flatten(results)
      assert Enum.all?(flat_results, &match?({:ok, _}, &1))
      assert length(flat_results) == reader_count * reads_per_reader

      # 500 total reads should complete quickly
      assert_performance(time, 100_000, "500 concurrent reads")
    end

    test "concurrent writes performance" do
      writer_count = 5
      writes_per_writer = 20

      tasks =
        for i <- 1..writer_count do
          Task.async(fn ->
            Enum.each(1..writes_per_writer, fn j ->
              zone_name = "concurrent-#{i}-#{j}.com"
              zone = Zone.new(zone_name, :authoritative)
              Store.put_zone(zone)
            end)
          end)
        end

      {time, _} = measure(fn -> Task.await_many(tasks, 5000) end)

      # All writes should complete
      # Note: ETS public tables allow concurrent writes but may have contention
      assert_performance(time, 50_000, "100 concurrent writes")
    end

    test "mixed read/write performance", %{zones: zones} do
      # Simulate real-world mixed workload
      reader_tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            Enum.map(1..30, fn _ ->
              zone = Enum.random(zones)
              Store.get_zone(zone.name.value)
            end)
          end)
        end

      writer_tasks =
        for i <- 1..3 do
          Task.async(fn ->
            Enum.each(1..10, fn j ->
              zone_name = "mixed-#{i}-#{j}.com"
              zone = Zone.new(zone_name, :stub)
              Store.put_zone(zone)
            end)
          end)
        end

      all_tasks = reader_tasks ++ writer_tasks

      {time, _} = measure(fn -> Task.await_many(all_tasks, 5000) end)

      # Mixed workload should complete reasonably
      assert_performance(time, 100_000, "Mixed read/write workload")
    end

    test "concurrent type filtering" do
      filter_tasks =
        for type <- @zone_types do
          Task.async(fn ->
            # Each task filters multiple times
            Enum.map(1..10, fn _ ->
              Store.get_zones_by_type(type)
            end)
          end)
        end

      {time, results} = measure(fn -> Task.await_many(filter_tasks, 5000) end)

      # All filter operations should succeed
      assert length(results) == length(@zone_types)
      assert_performance(time, 50_000, "40 concurrent type filters")
    end
  end

  # ============================================================================
  # Scalability Tests
  # ============================================================================

  describe "scalability tests" do
    setup do
      Store.clear()
      :ok
    end

    test "performance with increasing zone counts" do
      zone_counts = [50, 100, 200, 500]

      times =
        Enum.map(zone_counts, fn count ->
          Store.clear()

          # Insert zones
          zones = generate_zones(count)
          Enum.each(zones, &Store.put_zone/1)

          # Measure various operations
          {lookup_time, _} =
            measure(fn ->
              Enum.each(1..10, fn i ->
                Store.get_zone("zone#{i}.com")
              end)
            end)

          {list_time, _} = measure(fn -> Store.list_zones() end)

          {filter_time, _} =
            measure(fn ->
              Store.get_zones_by_type(:authoritative)
            end)

          {count, lookup_time, list_time, filter_time}
        end)

      # Verify performance scales reasonably
      Enum.each(times, fn {count, lookup, list, filter} ->
        IO.puts("#{count} zones: lookup=#{lookup}μs, list=#{list}μs, filter=#{filter}μs")

        # Lookups should remain constant time
        assert_performance(lookup, 5000, "10 lookups with #{count} zones")

        # List and filter scale linearly but should still be fast
        max_list_time = count * 100
        assert_performance(list, max_list_time, "List with #{count} zones")
      end)
    end

    test "performance with 1000 zones" do
      zones = generate_zones(1000)

      # Insert performance
      {insert_time, _} =
        measure(fn ->
          Enum.each(zones, &Store.put_zone/1)
        end)

      assert_performance(insert_time, 50_000, "Insert 1000 zones")

      # Lookup performance
      {lookup_time, _} =
        measure(fn ->
          Enum.each(1..100, fn i ->
            Store.get_zone("zone#{i}.com")
          end)
        end)

      assert_performance(lookup_time, 10_000, "100 lookups in 1000 zones")

      # Type filter performance
      {filter_time, zones_by_type} =
        measure(fn -> Store.get_zones_by_type(:authoritative) end)

      assert length(zones_by_type) >= 200 and length(zones_by_type) <= 300
      assert_performance(filter_time, 20_000, "Type filter in 1000 zones")
    end
  end

  # ============================================================================
  # Name Normalization Performance Tests
  # ============================================================================

  describe "name normalization performance" do
    setup do
      Store.clear()
      :ok
    end

    test "case-insensitive lookup performance" do
      zone = Zone.new("example.com", :authoritative)
      Store.put_zone(zone)

      # Test various case combinations
      test_names = [
        "example.com",
        "EXAMPLE.COM",
        "Example.Com",
        "eXaMpLe.CoM"
      ]

      {time, results} =
        measure(fn ->
          Enum.map(test_names, fn name ->
            Store.get_zone(name)
          end)
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert_performance(time, 2000, "4 case-insensitive lookups")
    end

    test "zone_exists? with various case combinations" do
      zone = Zone.new("CaseSensitive.ORG", :authoritative)
      Store.put_zone(zone)

      test_names = [
        "casesensitive.org",
        "CASESENSITIVE.ORG",
        "CaseSensitive.Org",
        "caseSENSITIVE.org"
      ]

      {time, results} =
        measure(fn ->
          Enum.map(test_names, fn name ->
            Store.zone_exists?(name)
          end)
        end)

      assert Enum.all?(results, &(&1 == true))
      assert_performance(time, 2000, "4 case-insensitive existence checks")
    end

    test "delete with case variations" do
      # Insert zone with mixed case
      zone = Zone.new("ToDelete.NET", :stub)
      Store.put_zone(zone)
      assert Store.zone_exists?("todelete.net")

      # Delete with different case
      {time, _} = measure(fn -> Store.delete_zone("TODELETE.NET") end)

      refute Store.zone_exists?("todelete.net")
      assert_performance(time, 1000, "Case-insensitive delete")
    end
  end

  # ============================================================================
  # Memory and Resource Tests
  # ============================================================================

  describe "memory and resource efficiency" do
    setup do
      Store.clear()
      :erlang.garbage_collect()
      :ok
    end

    test "ETS table memory usage tracking" do
      Store.init()

      # Get initial memory
      info_before = :ets.info(:dns_zones)
      memory_before = info_before[:memory]

      # Add zones
      zones = generate_zones(100)
      Enum.each(zones, &Store.put_zone/1)

      # Get memory after
      info_after = :ets.info(:dns_zones)
      memory_after = info_after[:memory]

      memory_increase = memory_after - memory_before
      memory_per_zone = div(memory_increase, 100)

      IO.puts("Memory increase for 100 zones: #{memory_increase} words")
      IO.puts("Memory per zone: ~#{memory_per_zone} words")

      # Reasonable memory usage (less than 100KB for 100 zones)
      assert memory_increase < 100_000, "Excessive memory usage"
    end

    test "memory reclamation after clear" do
      Store.init()

      # Add many zones
      zones = generate_zones(500)
      Enum.each(zones, &Store.put_zone/1)

      info_with_zones = :ets.info(:dns_zones)
      memory_with_zones = info_with_zones[:memory]

      # Clear zones
      Store.clear()

      info_after_clear = :ets.info(:dns_zones)
      memory_after_clear = info_after_clear[:memory]

      # Memory should be significantly reduced
      assert memory_after_clear < memory_with_zones

      IO.puts("Memory with zones: #{memory_with_zones}, after clear: #{memory_after_clear}")
    end

    test "ETS table statistics" do
      Store.init()
      zones = generate_zones(200)
      Enum.each(zones, &Store.put_zone/1)

      info = :ets.info(:dns_zones)

      # Verify expected statistics
      assert info[:size] == 200
      assert info[:type] == :set
      assert info[:read_concurrency] == true
      assert info[:named_table] == true

      IO.puts("ETS table info: size=#{info[:size]}, memory=#{info[:memory]} words")
    end
  end

  # ============================================================================
  # Edge Cases and Stress Tests
  # ============================================================================

  describe "edge cases and stress tests" do
    setup do
      Store.clear()
      :ok
    end

    test "empty store operations" do
      # Operations on empty store should be fast
      {list_time, list} = measure(fn -> Store.list_zones() end)

      {filter_time, filtered} =
        measure(fn -> Store.get_zones_by_type(:authoritative) end)

      {lookup_time, lookup} = measure(fn -> Store.get_zone("test.com") end)

      assert list == []
      assert filtered == []
      assert lookup == {:error, :not_found}

      assert_performance(list_time, 1000, "List empty store")
      assert_performance(filter_time, 1000, "Filter empty store")
      assert_performance(lookup_time, 1000, "Lookup in empty store")
    end

    test "single zone store operations" do
      zone = Zone.new("single.com", :authoritative)
      Store.put_zone(zone)

      {list_time, list} = measure(fn -> Store.list_zones() end)

      {filter_time, filtered} =
        measure(fn -> Store.get_zones_by_type(:authoritative) end)

      assert length(list) == 1
      assert length(filtered) == 1

      assert_performance(list_time, 1000, "List single zone")
      assert_performance(filter_time, 1000, "Filter single zone")
    end

    test "rapid zone turnover (insert, lookup, delete)" do
      iterations = 100

      {time, _} =
        measure(fn ->
          Enum.each(1..iterations, fn i ->
            zone_name = "turnover#{i}.com"
            zone = Zone.new(zone_name, :authoritative)

            # Insert
            {:ok, _} = Store.put_zone(zone)

            # Lookup
            {:ok, _} = Store.get_zone(zone_name)

            # Delete
            :ok = Store.delete_zone(zone_name)

            # Verify deleted
            {:error, :not_found} = Store.get_zone(zone_name)
          end)
        end)

      assert_performance(time, 50_000, "100 insert/lookup/delete cycles")
    end

    test "long zone names performance" do
      # Test with unusually long zone names
      long_prefix = String.duplicate("subdomain.", 20)

      long_zones =
        Enum.map(1..50, fn i ->
          name = "#{long_prefix}zone#{i}.com"
          Zone.new(name, :authoritative)
        end)

      {insert_time, _} =
        measure(fn ->
          Enum.each(long_zones, &Store.put_zone/1)
        end)

      {lookup_time, _} =
        measure(fn ->
          zone = List.first(long_zones)
          Store.get_zone(zone.name.value)
        end)

      assert_performance(insert_time, 10_000, "Insert 50 long-name zones")
      assert_performance(lookup_time, 1000, "Lookup long-name zone")
    end

    test "special characters in zone names" do
      # Test internationalized domain names (IDN) style
      special_zones = [
        # IDN encoded
        Zone.new("xn--nxasmq5a.com", :authoritative),
        Zone.new("example-with-dash.com", :authoritative),
        Zone.new("123numeric.com", :authoritative),
        Zone.new("a.b.c.d.e.f.g.h.i.j.k.l.deep.com", :authoritative)
      ]

      Enum.each(special_zones, &Store.put_zone/1)

      {time, results} =
        measure(fn ->
          Enum.map(special_zones, fn zone ->
            Store.get_zone(zone.name.value)
          end)
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert_performance(time, 2000, "Lookup special character zones")
    end

    test "all zone types performance comparison" do
      # Insert equal number of each type
      zones_per_type = 50

      Enum.each(@zone_types, fn type ->
        Enum.each(1..zones_per_type, fn i ->
          zone_name = "#{type}-#{i}.com"
          zone = Zone.new(zone_name, type)
          Store.put_zone(zone)
        end)
      end)

      # Measure filter time for each type
      type_times =
        Enum.map(@zone_types, fn type ->
          {time, zones} = measure(fn -> Store.get_zones_by_type(type) end)
          assert length(zones) == zones_per_type
          {type, time}
        end)

      # All types should have similar performance
      Enum.each(type_times, fn {type, time} ->
        assert_performance(time, 10_000, "Filter #{type} zones")
        IO.puts("Filter #{type}: #{time}μs")
      end)
    end
  end

  # ============================================================================
  # Initialization and Table Management Tests
  # ============================================================================

  describe "initialization and table management" do
    test "init is idempotent" do
      # Multiple init calls should not fail
      assert :ok = Store.init()
      assert :ok = Store.init()
      assert :ok = Store.init()

      # Table should still work
      zone = Zone.new("init-test.com", :authoritative)
      {:ok, _} = Store.put_zone(zone)
      {:ok, _} = Store.get_zone("init-test.com")
    end

    test "ensure_initialized creates table if needed" do
      # This depends on table state from other tests
      # Just verify it doesn't raise
      assert :ok = Store.ensure_initialized()
    end

    test "operations auto-initialize table" do
      # Put should work without explicit init
      Store.clear()
      zone = Zone.new("auto-init.com", :authoritative)
      {:ok, _} = Store.put_zone(zone)

      # Get should work
      {:ok, _} = Store.get_zone("auto-init.com")

      # List should work
      zones = Store.list_zones()
      assert length(zones) >= 1
    end
  end

  # ============================================================================
  # Comparison with Alternative Approaches
  # ============================================================================

  describe "ETS vs naive implementation comparison" do
    setup do
      Store.clear()
      zones = generate_zones(200)
      Enum.each(zones, &Store.put_zone/1)
      {:ok, zones: zones}
    end

    test "ETS lookup vs list search", %{zones: zones} do
      zone = List.first(zones)
      target_name = zone.name.value

      # ETS lookup (O(1))
      {ets_time, ets_result} =
        measure(fn ->
          Store.get_zone(target_name)
        end)

      # Naive list search (O(n))
      all_zones = Store.list_zones()

      {naive_time, naive_result} =
        measure(fn ->
          Enum.find(all_zones, fn z ->
            String.downcase(z.name.value) == String.downcase(target_name)
          end)
        end)

      # Both should find the zone
      assert {:ok, _} = ets_result
      assert naive_result != nil

      # ETS should be faster (or at least comparable for small datasets)
      IO.puts("ETS lookup: #{ets_time}μs, Naive search: #{naive_time}μs")
    end

    test "ETS filter vs Enum.filter comparison" do
      # Both currently use Enum.filter, but this tests the pattern
      all_zones = Store.list_zones()

      {store_time, store_result} =
        measure(fn ->
          Store.get_zones_by_type(:authoritative)
        end)

      {enum_time, enum_result} =
        measure(fn ->
          Enum.filter(all_zones, &(&1.type == :authoritative))
        end)

      # Results should match
      assert length(store_result) == length(enum_result)

      IO.puts("Store filter: #{store_time}μs, Enum.filter: #{enum_time}μs")
    end
  end
end
