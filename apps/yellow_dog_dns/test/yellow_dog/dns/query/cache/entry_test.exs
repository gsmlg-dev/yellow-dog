defmodule YellowDog.Dns.Query.Cache.EntryTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.Query.Cache.Entry
  alias YellowDog.Dns.Zone

  describe "new/6" do
    test "creates entry with default values" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 300)]
      entry = Entry.new("www.example.com.", :A, records, [], 300)

      assert entry.query_name == "www.example.com."
      assert entry.query_type == :A
      assert entry.query_class == :IN
      assert entry.response_type == :answer
      assert entry.records == records
      assert entry.authority == []
      assert entry.ttl == 300
      assert entry.hit_count == 0
      assert is_integer(entry.inserted_at)
      assert is_integer(entry.expires_at)
    end

    test "normalizes query name to lowercase with trailing dot" do
      entry = Entry.new("WWW.EXAMPLE.COM", :A, [], [], 300)
      assert entry.query_name == "www.example.com."

      entry = Entry.new("www.example.com", :A, [], [], 300)
      assert entry.query_name == "www.example.com."
    end

    test "creates entry with custom query class" do
      entry = Entry.new("example.com.", :A, [], [], 300, query_class: :CH)
      assert entry.query_class == :CH
    end

    test "determines response type from records" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1})]
      entry = Entry.new("www.example.com.", :A, records, [], 300)
      assert entry.response_type == :answer

      entry = Entry.new("www.example.com.", :A, [], [], 300)
      assert entry.response_type == :nxdomain

      entry = Entry.new("www.example.com.", :A, [], [], 300, response_type: :nodata)
      assert entry.response_type == :nodata
    end

    test "calculates expiration time correctly" do
      ttl = 300
      entry = Entry.new("example.com.", :A, [], [], ttl)

      assert entry.expires_at == entry.inserted_at + ttl
    end
  end

  describe "expired?/1" do
    test "returns false for fresh entry" do
      entry = Entry.new("example.com.", :A, [], [], 300)
      refute Entry.expired?(entry)
    end

    test "returns true for expired entry" do
      # Create entry with past expiration
      now = System.monotonic_time(:second)
      entry = Entry.new("example.com.", :A, [], [], 300, inserted_at: now - 400)

      assert Entry.expired?(entry)
    end

    test "returns true for entry expiring now" do
      now = System.monotonic_time(:second)
      entry = Entry.new("example.com.", :A, [], [], 0, inserted_at: now)

      # May need a small sleep to ensure expiration
      Process.sleep(10)
      assert Entry.expired?(entry)
    end
  end

  describe "remaining_ttl/1" do
    test "returns correct remaining TTL for fresh entry" do
      entry = Entry.new("example.com.", :A, [], [], 300)
      remaining = Entry.remaining_ttl(entry)

      assert remaining > 295
      assert remaining <= 300
    end

    test "returns 0 for expired entry" do
      now = System.monotonic_time(:second)
      entry = Entry.new("example.com.", :A, [], [], 300, inserted_at: now - 400)

      assert Entry.remaining_ttl(entry) == 0
    end

    test "returns decreasing values as time passes" do
      entry = Entry.new("example.com.", :A, [], [], 300)
      first_ttl = Entry.remaining_ttl(entry)

      Process.sleep(10)
      second_ttl = Entry.remaining_ttl(entry)

      assert second_ttl <= first_ttl
    end
  end

  describe "record_hit/1" do
    test "increments hit count" do
      entry = Entry.new("example.com.", :A, [], [], 300)
      assert entry.hit_count == 0

      entry = Entry.record_hit(entry)
      assert entry.hit_count == 1

      entry = Entry.record_hit(entry)
      assert entry.hit_count == 2
    end
  end

  describe "update_ttls/1" do
    test "updates TTL in records to remaining TTL" do
      records = [
        Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 300),
        Zone.Record.new("www.example.com.", :AAAA, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, ttl: 300)
      ]

      entry = Entry.new("www.example.com.", :A, records, [], 300)
      updated = Entry.update_ttls(entry)

      remaining = Entry.remaining_ttl(entry)

      Enum.each(updated.records, fn record ->
        assert record.ttl == remaining
      end)
    end

    test "updates TTL in authority records" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 300)]

      authority = [
        Zone.Record.new("example.com.", :NS, "ns1.example.com.", ttl: 3600)
      ]

      entry = Entry.new("www.example.com.", :A, records, authority, 300)
      updated = Entry.update_ttls(entry)

      remaining = Entry.remaining_ttl(entry)

      Enum.each(updated.authority, fn record ->
        assert record.ttl == remaining
      end)
    end

    test "handles SOA records in authority section" do
      soa = %Zone.SOA{
        mname: "ns1.example.com.",
        rname: "admin.example.com.",
        serial: 2_024_102_901,
        refresh: 7200,
        retry: 3600,
        expire: 1_209_600,
        minimum: 3600
      }

      entry = Entry.new("www.example.com.", :A, [], [soa], 300)
      updated = Entry.update_ttls(entry)

      # SOA records don't have TTL field, should be unchanged
      assert hd(updated.authority) == soa
    end
  end

  describe "cache_key/3" do
    test "generates consistent cache key" do
      key1 = Entry.cache_key("www.example.com.", :A, :IN)
      key2 = Entry.cache_key("www.example.com.", :A, :IN)

      assert key1 == key2
      assert key1 == {"www.example.com.", :A, :IN}
    end

    test "normalizes name in cache key" do
      key1 = Entry.cache_key("WWW.EXAMPLE.COM", :A)
      key2 = Entry.cache_key("www.example.com.", :A)

      assert key1 == key2
    end

    test "generates different keys for different types" do
      key_a = Entry.cache_key("www.example.com.", :A)
      key_aaaa = Entry.cache_key("www.example.com.", :AAAA)

      assert key_a != key_aaaa
    end

    test "generates different keys for different classes" do
      key_in = Entry.cache_key("www.example.com.", :A, :IN)
      key_ch = Entry.cache_key("www.example.com.", :A, :CH)

      assert key_in != key_ch
    end

    test "defaults to IN class" do
      key1 = Entry.cache_key("www.example.com.", :A)
      key2 = Entry.cache_key("www.example.com.", :A, :IN)

      assert key1 == key2
    end
  end
end
