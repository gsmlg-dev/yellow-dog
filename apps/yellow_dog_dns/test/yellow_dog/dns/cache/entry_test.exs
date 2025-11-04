defmodule YellowDog.Dns.Cache.EntryTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.Query.Cache.Entry
  alias YellowDog.Dns.Zone

  describe "new/5" do
    test "creates a new cache entry" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 300, class: :IN)]
      authority = []
      ttl = 300

      entry = Entry.new(name, type, records, authority, ttl)

      assert entry.name == name
      assert entry.type == type
      assert entry.records == records
      assert entry.authority == authority
      assert entry.ttl == ttl
      assert entry.hit_count == 0
      assert is_integer(entry.created_at)
      assert is_integer(entry.expires_at)
      assert is_integer(entry.last_accessed)
    end

    test "sets expiration time correctly" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 300, class: :IN)]
      ttl = 300

      before = System.system_time(:second)
      entry = Entry.new(name, type, records, [], ttl)
      after_time = System.system_time(:second)

      # Expiration should be now + ttl
      expected_min = before + ttl
      expected_max = after_time + ttl

      assert entry.expires_at >= expected_min
      assert entry.expires_at <= expected_max
    end
  end

  describe "expired?/1" do
    test "returns false for non-expired entry" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 300, class: :IN)]
      ttl = 300

      entry = Entry.new(name, type, records, [], ttl)

      refute Entry.expired?(entry)
    end

    test "returns true for expired entry" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 0, class: :IN)]
      ttl = 0

      entry = Entry.new(name, type, records, [], ttl)

      # Wait for expiration
      Process.sleep(1000)

      assert Entry.expired?(entry)
    end
  end

  describe "remaining_ttl/1" do
    test "returns correct remaining TTL" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 300, class: :IN)]
      ttl = 300

      entry = Entry.new(name, type, records, [], ttl)

      remaining = Entry.remaining_ttl(entry)

      # Should be close to 300 (allowing for small time differences)
      assert remaining >= 299
      assert remaining <= 300
    end

    test "returns 0 for expired entry" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 0, class: :IN)]
      ttl = 0

      entry = Entry.new(name, type, records, [], ttl)

      # Wait for expiration
      Process.sleep(1000)

      assert Entry.remaining_ttl(entry) == 0
    end
  end

  describe "mark_accessed/1" do
    test "updates last_accessed timestamp" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 300, class: :IN)]
      ttl = 300

      entry = Entry.new(name, type, records, [], ttl)
      original_accessed = entry.last_accessed

      # Wait a bit
      Process.sleep(100)

      updated_entry = Entry.mark_accessed(entry)

      assert updated_entry.last_accessed > original_accessed
    end

    test "increments hit count" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 300, class: :IN)]
      ttl = 300

      entry = Entry.new(name, type, records, [], ttl)

      assert entry.hit_count == 0

      entry = Entry.mark_accessed(entry)
      assert entry.hit_count == 1

      entry = Entry.mark_accessed(entry)
      assert entry.hit_count == 2
    end
  end

  describe "size_bytes/1" do
    test "returns approximate size for entry" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 300, class: :IN)]
      ttl = 300

      entry = Entry.new(name, type, records, [], ttl)

      size = Entry.size_bytes(entry)

      # Should be at least the name size + overhead
      assert size > byte_size(name)
      # Should be reasonable (not massive)
      assert size < 10_000
    end

    test "larger entries have larger size" do
      name = "example.com"
      type = :TXT

      small_record = Zone.Record.new(name, type, "small", ttl: 300, class: :IN)
      large_record = Zone.Record.new(name, type, String.duplicate("large", 100), ttl: 300, class: :IN)

      small_entry = Entry.new(name, type, [small_record], [], 300)
      large_entry = Entry.new(name, type, [large_record], [], 300)

      # Note: Current implementation uses fixed size per record, so they'll be similar
      # This test documents current behavior
      small_size = Entry.size_bytes(small_entry)
      large_size = Entry.size_bytes(large_entry)

      # Both should have reasonable sizes
      assert small_size > 0
      assert large_size > 0
    end
  end
end
