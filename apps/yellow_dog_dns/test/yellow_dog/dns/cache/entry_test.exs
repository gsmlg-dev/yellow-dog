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

      assert entry.query_name == "example.com."
      assert entry.query_type == type
      assert entry.query_class == :IN
      assert entry.records == records
      assert entry.authority == authority
      assert entry.ttl == ttl
      assert entry.hit_count == 0
      assert is_integer(entry.inserted_at)
      assert is_integer(entry.expires_at)
    end

    test "sets expiration time correctly" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 300, class: :IN)]
      ttl = 300

      before = System.monotonic_time(:second)
      entry = Entry.new(name, type, records, [], ttl)
      after_time = System.monotonic_time(:second)

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

  describe "record_hit/1" do
    test "increments hit count" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 300, class: :IN)]
      ttl = 300

      entry = Entry.new(name, type, records, [], ttl)

      assert entry.hit_count == 0

      entry = Entry.record_hit(entry)
      assert entry.hit_count == 1

      entry = Entry.record_hit(entry)
      assert entry.hit_count == 2
    end

    test "returns updated entry" do
      name = "example.com"
      type = :A
      records = [Zone.Record.new(name, type, {192, 168, 1, 1}, ttl: 300, class: :IN)]
      ttl = 300

      entry = Entry.new(name, type, records, [], ttl)
      updated_entry = Entry.record_hit(entry)

      # Should return a new entry struct
      assert updated_entry.hit_count == entry.hit_count + 1
      assert updated_entry.query_name == entry.query_name
    end
  end
end
