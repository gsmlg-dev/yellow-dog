defmodule YellowDog.Store.CacheTest do
  use ExUnit.Case, async: false

  alias YellowDog.Store.Cache

  @table :yellow_dog_dns_cache

  setup do
    # Clean up ETS table and persistent_term state before each test
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@table)
    end

    # Reset counters
    Cache.ensure_table()

    # Reset configuration to defaults
    :persistent_term.erase({Cache, :max_memory_bytes})
    :persistent_term.erase({Cache, :batch_size})
    :persistent_term.erase({Cache, :flush_interval_ms})

    # Re-initialize counters so each test starts at zero
    ref = :counters.new(2, [:write_concurrency])
    :persistent_term.put({Cache, :counters}, ref)

    on_exit(fn ->
      case :ets.whereis(@table) do
        :undefined -> :ok
        _ref -> :ets.delete_all_objects(@table)
      end

      :persistent_term.erase({Cache, :max_memory_bytes})
      :persistent_term.erase({Cache, :batch_size})
      :persistent_term.erase({Cache, :flush_interval_ms})
    end)

    :ok
  end

  defp make_entry(opts \\ []) do
    %{
      rrset: Keyword.get(opts, :rrset, []),
      qname: Keyword.get(opts, :qname, "example.com"),
      qtype: Keyword.get(opts, :qtype, :a),
      rcode: Keyword.get(opts, :rcode, :noerror),
      upstream: Keyword.get(opts, :upstream, "8.8.8.8"),
      fetched_at: Keyword.get(opts, :fetched_at, System.system_time(:second)),
      original_ttl: Keyword.get(opts, :original_ttl, 300),
      negative: Keyword.get(opts, :negative, false)
    }
  end

  describe "store/3 and lookup/2 round-trip" do
    test "stores and retrieves an entry" do
      entry = make_entry()
      assert :ok = Cache.store("example.com", :a, entry)
      assert {:ok, ^entry} = Cache.lookup("example.com", :a)
    end

    test "returns not_found for missing entry" do
      assert {:error, :not_found} = Cache.lookup("nonexistent.com", :a)
    end

    test "different qname/qtype pairs are independent" do
      entry_a = make_entry(qtype: :a)
      entry_aaaa = make_entry(qtype: :aaaa)

      Cache.store("example.com", :a, entry_a)
      Cache.store("example.com", :aaaa, entry_aaaa)

      assert {:ok, ^entry_a} = Cache.lookup("example.com", :a)
      assert {:ok, ^entry_aaaa} = Cache.lookup("example.com", :aaaa)
    end

    test "overwriting an entry replaces it" do
      entry1 = make_entry(upstream: "8.8.8.8")
      entry2 = make_entry(upstream: "1.1.1.1")

      Cache.store("example.com", :a, entry1)
      Cache.store("example.com", :a, entry2)

      assert {:ok, result} = Cache.lookup("example.com", :a)
      assert result.upstream == "1.1.1.1"
    end
  end

  describe "TTL expiry" do
    test "expired entries return not_found" do
      past = System.system_time(:second) - 600
      entry = make_entry(fetched_at: past, original_ttl: 300)

      Cache.store("expired.com", :a, entry)

      assert {:error, :not_found} = Cache.lookup("expired.com", :a)
    end

    test "non-expired entries are returned" do
      now = System.system_time(:second)
      entry = make_entry(fetched_at: now, original_ttl: 300)

      Cache.store("fresh.com", :a, entry)

      assert {:ok, _} = Cache.lookup("fresh.com", :a)
    end

    test "expired entry is deleted from ETS on lookup" do
      past = System.system_time(:second) - 600
      entry = make_entry(fetched_at: past, original_ttl: 300)

      Cache.store("stale.com", :a, entry)

      # First lookup triggers deletion
      assert {:error, :not_found} = Cache.lookup("stale.com", :a)

      # Verify the key is gone from ETS
      assert :ets.lookup(@table, {"stale.com", :a}) == []
    end
  end

  describe "invalidate/2" do
    test "removes entry from ETS" do
      entry = make_entry()
      Cache.store("example.com", :a, entry)

      assert :ok = Cache.invalidate("example.com", :a)
      assert {:error, :not_found} = Cache.lookup("example.com", :a)
    end

    test "invalidating nonexistent entry is a no-op" do
      assert :ok = Cache.invalidate("nonexistent.com", :a)
    end
  end

  describe "invalidate_all/0" do
    test "clears all entries from ETS" do
      Cache.store("a.com", :a, make_entry())
      Cache.store("b.com", :a, make_entry())
      Cache.store("c.com", :aaaa, make_entry())

      assert :ok = Cache.invalidate_all()

      assert {:error, :not_found} = Cache.lookup("a.com", :a)
      assert {:error, :not_found} = Cache.lookup("b.com", :a)
      assert {:error, :not_found} = Cache.lookup("c.com", :aaaa)
    end

    test "resets hit/miss counters" do
      Cache.store("x.com", :a, make_entry())
      Cache.lookup("x.com", :a)
      Cache.lookup("missing.com", :a)

      Cache.invalidate_all()

      stats = Cache.stats()
      assert stats.hits == 0
      assert stats.misses == 0
    end
  end

  describe "stats/0" do
    test "returns proper structure" do
      stats = Cache.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :hits)
      assert Map.has_key?(stats, :misses)
      assert Map.has_key?(stats, :size)
      assert Map.has_key?(stats, :memory_bytes)
      assert Map.has_key?(stats, :max_memory_bytes)
      assert Map.has_key?(stats, :hit_rate)
    end

    test "size reflects stored entries" do
      assert Cache.stats().size == 0

      Cache.store("a.com", :a, make_entry())
      assert Cache.stats().size == 1

      Cache.store("b.com", :a, make_entry())
      assert Cache.stats().size == 2
    end

    test "hit_rate is 0.0 when no lookups" do
      assert Cache.stats().hit_rate == 0.0
    end
  end

  describe "hit/miss counters" do
    test "hit counter increments on cache hit" do
      entry = make_entry()
      Cache.store("hit.com", :a, entry)

      Cache.lookup("hit.com", :a)
      Cache.lookup("hit.com", :a)

      stats = Cache.stats()
      assert stats.hits == 2
    end

    test "miss counter increments on cache miss" do
      Cache.lookup("miss1.com", :a)
      Cache.lookup("miss2.com", :aaaa)

      stats = Cache.stats()
      assert stats.misses == 2
    end

    test "expired lookup counts as miss" do
      past = System.system_time(:second) - 600
      entry = make_entry(fetched_at: past, original_ttl: 300)
      Cache.store("old.com", :a, entry)

      Cache.lookup("old.com", :a)

      stats = Cache.stats()
      assert stats.misses == 1
      assert stats.hits == 0
    end

    test "hit_rate computes correctly" do
      entry = make_entry()
      Cache.store("x.com", :a, entry)

      # 3 hits
      Cache.lookup("x.com", :a)
      Cache.lookup("x.com", :a)
      Cache.lookup("x.com", :a)
      # 1 miss
      Cache.lookup("missing.com", :a)

      stats = Cache.stats()
      assert stats.hits == 3
      assert stats.misses == 1
      assert stats.hit_rate == 0.75
    end
  end

  describe "LRU eviction" do
    test "evicts oldest entries when memory budget exceeded" do
      # Set an extremely small memory budget to force eviction
      Cache.configure(max_memory_bytes: 1)

      # Store enough entries to exceed the budget
      for i <- 1..20 do
        Cache.store("evict#{i}.com", :a, make_entry(qname: "evict#{i}.com"))
      end

      # After eviction, the table should have fewer than 20 entries
      stats = Cache.stats()
      assert stats.size < 20
    end
  end

  describe "configure/1" do
    test "updates max_memory_bytes" do
      Cache.configure(max_memory_bytes: 128 * 1024 * 1024)
      stats = Cache.stats()
      assert stats.max_memory_bytes == 128 * 1024 * 1024
    end

    test "updates flush_interval_ms" do
      assert :ok = Cache.configure(flush_interval_ms: 5000)
    end

    test "ignores unknown keys" do
      assert :ok = Cache.configure(unknown_key: "value")
    end
  end

  describe "ensure_table/0" do
    test "creates table if it does not exist" do
      # Delete the table first
      case :ets.whereis(@table) do
        :undefined -> :ok
        _ref -> :ets.delete(@table)
      end

      assert :ok = Cache.ensure_table()
      assert :ets.whereis(@table) != :undefined
    end

    test "is idempotent when table already exists" do
      Cache.ensure_table()
      assert :ok = Cache.ensure_table()
    end
  end

  describe "warm_from_store/0" do
    @tag :store_integration
    @tag :skip
    test "loads entries from Concord into ETS" do
      # Requires running Concord cluster
      assert :ok = Cache.warm_from_store()
    end
  end

  describe "flush_to_store/0" do
    @tag :store_integration
    @tag :skip
    test "writes recent ETS entries to Concord" do
      # Requires running Concord cluster
      assert :ok = Cache.flush_to_store()
    end
  end
end
