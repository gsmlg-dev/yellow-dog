defmodule YellowDog.Dns.Query.ResolverTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Query.Resolver
  alias YellowDog.Dns.Zone
  alias YellowDog.Dns.Zone.Storage

  setup do
    # Initialize storage (ignore if already exists)
    case Storage.init() do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end

    # Create a test zone with various records
    zone_name = "test.com"

    # Store SOA
    soa = Zone.SOA.new("ns1.test.com.", "admin.test.com.", 2024010101,
      refresh: 3600,
      retry: 1800,
      expire: 604_800,
      minimum: 300
    )
    Storage.insert_record(zone_name, "@", :SOA, soa, 3600)

    # Store NS records
    Storage.insert_record(zone_name, "@", :NS, "ns1.test.com.", 3600)
    Storage.insert_record(zone_name, "@", :NS, "ns2.test.com.", 3600)

    # Store A records
    Storage.insert_record(zone_name, "www.test.com.", :A, {192, 168, 1, 100}, 300)
    Storage.insert_record(zone_name, "mail.test.com.", :A, {192, 168, 1, 20}, 300)
    Storage.insert_record(zone_name, "ns1.test.com.", :A, {192, 168, 1, 10}, 3600)

    # Store AAAA record
    Storage.insert_record(zone_name, "www.test.com.", :AAAA, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 300)

    # Store MX record
    Storage.insert_record(zone_name, "@", :MX, {10, "mail.test.com."}, 600)

    # Store TXT record
    Storage.insert_record(zone_name, "@", :TXT, "v=spf1 mx a -all", 3600)

    # Store CNAME record
    Storage.insert_record(zone_name, "ftp.test.com.", :CNAME, "www.test.com.", 300)

    # Store zone metadata
    Storage.put_zone_metadata(zone_name, %{
      type: :master,
      serial: 2024010101,
      loaded_at: System.system_time(:second)
    })

    on_exit(fn ->
      # Clean up - ignore errors if tables don't exist
      try do
        Storage.delete_zone(zone_name)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  describe "resolve/3" do
    test "resolves A record successfully" do
      assert {:ok, [record], []} = Resolver.resolve("test.com", "www.test.com.", :A)

      assert record.owner == "www.test.com."
      assert record.type == :A
      assert record.rdata == {192, 168, 1, 100}
      assert record.ttl == 300
    end

    test "resolves AAAA record successfully" do
      assert {:ok, [record], []} = Resolver.resolve("test.com", "www.test.com.", :AAAA)

      assert record.owner == "www.test.com."
      assert record.type == :AAAA
      assert record.rdata == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      assert record.ttl == 300
    end

    test "resolves MX record successfully" do
      assert {:ok, [record], []} = Resolver.resolve("test.com", "@", :MX)

      assert record.owner == "@"
      assert record.type == :MX
      assert record.rdata == {10, "mail.test.com."}
      assert record.ttl == 600
    end

    test "resolves TXT record successfully" do
      assert {:ok, [record], []} = Resolver.resolve("test.com", "@", :TXT)

      assert record.owner == "@"
      assert record.type == :TXT
      assert record.rdata == "v=spf1 mx a -all"
    end

    test "resolves NS records successfully" do
      assert {:ok, [record], []} = Resolver.resolve("test.com", "@", :NS)

      assert record.owner == "@"
      assert record.type == :NS
      assert record.rdata in ["ns1.test.com.", "ns2.test.com."]
    end

    test "returns NXDOMAIN for non-existent name" do
      assert {:nxdomain, [], authority} = Resolver.resolve("test.com", "nonexistent.test.com.", :A)

      assert length(authority) == 1
      assert hd(authority).__struct__ == Zone.SOA
    end

    test "returns NODATA when name exists but type doesn't" do
      assert {:nodata, [], authority} = Resolver.resolve("test.com", "www.test.com.", :MX)

      assert length(authority) == 1
      assert hd(authority).__struct__ == Zone.SOA
    end

    test "returns SERVFAIL for non-existent zone" do
      assert {:servfail, [], []} = Resolver.resolve("nonexistent.com", "www", :A)
    end

    test "resolves with relative owner name" do
      assert {:ok, [record], []} = Resolver.resolve("test.com", "www", :A)

      assert record.owner == "www.test.com."
      assert record.type == :A
      assert record.rdata == {192, 168, 1, 100}
    end

    test "handles @ as zone apex" do
      assert {:ok, [record], []} = Resolver.resolve("test.com", "@", :SOA)

      assert record.owner == "@"
      assert record.type == :SOA
      assert record.rdata.__struct__ == Zone.SOA
    end
  end

  describe "resolve_with_cname/4" do
    test "follows CNAME to A record" do
      assert {:ok, answers, []} = Resolver.resolve_with_cname("test.com", "ftp.test.com.", :A)

      # Should have CNAME + A record
      assert length(answers) == 2

      cname_record = Enum.find(answers, &(&1.type == :CNAME))
      a_record = Enum.find(answers, &(&1.type == :A))

      assert cname_record.owner == "ftp.test.com."
      assert cname_record.rdata == "www.test.com."

      assert a_record.owner == "www.test.com."
      assert a_record.rdata == {192, 168, 1, 100}
    end

    test "returns CNAME without target when querying for CNAME type" do
      assert {:ok, [record], []} = Resolver.resolve_with_cname("test.com", "ftp.test.com.", :CNAME)

      assert record.type == :CNAME
      assert record.rdata == "www.test.com."
    end

    test "returns direct answer without CNAME" do
      assert {:ok, [record], []} = Resolver.resolve_with_cname("test.com", "www.test.com.", :A)

      assert record.type == :A
      assert record.rdata == {192, 168, 1, 100}
    end

    test "returns NXDOMAIN when CNAME target doesn't exist" do
      # Add CNAME to non-existent target
      Storage.insert_record("test.com", "broken.test.com.", :CNAME, "nonexistent.test.com.", 300)

      assert {:nxdomain, answers, _authority} =
               Resolver.resolve_with_cname("test.com", "broken.test.com.", :A)

      # Should have the CNAME in answers
      assert length(answers) == 1
      assert hd(answers).type == :CNAME
    end

    test "prevents CNAME loops with max depth" do
      # Create CNAME loop
      Storage.insert_record("test.com", "loop1.test.com.", :CNAME, "loop2.test.com.", 300)
      Storage.insert_record("test.com", "loop2.test.com.", :CNAME, "loop1.test.com.", 300)

      assert {:servfail, answers, []} =
               Resolver.resolve_with_cname("test.com", "loop1.test.com.", :A, max_depth: 5)

      # Should have collected some CNAMEs before hitting max depth
      assert length(answers) > 0
    end

    test "handles CNAME chain" do
      # Create CNAME chain: alias1 -> alias2 -> www
      Storage.insert_record("test.com", "alias1.test.com.", :CNAME, "alias2.test.com.", 300)
      Storage.insert_record("test.com", "alias2.test.com.", :CNAME, "www.test.com.", 300)

      assert {:ok, answers, []} = Resolver.resolve_with_cname("test.com", "alias1.test.com.", :A)

      # Should have 2 CNAMEs + 1 A record
      assert length(answers) == 3

      cname_records = Enum.filter(answers, &(&1.type == :CNAME))
      a_records = Enum.filter(answers, &(&1.type == :A))

      assert length(cname_records) == 2
      assert length(a_records) == 1
    end
  end

  describe "case insensitivity" do
    test "resolves with different case" do
      assert {:ok, [record], []} = Resolver.resolve("TEST.COM", "WWW.TEST.COM.", :A)
      assert record.rdata == {192, 168, 1, 100}

      assert {:ok, [record], []} = Resolver.resolve("Test.Com", "Www.Test.Com.", :A)
      assert record.rdata == {192, 168, 1, 100}
    end
  end

  describe "edge cases" do
    test "handles empty zone" do
      Storage.put_zone_metadata("empty.com", %{type: :master})

      assert {:nxdomain, [], []} = Resolver.resolve("empty.com", "www", :A)
    end

    test "handles zone with only SOA" do
      Storage.put_zone_metadata("minimal.com", %{type: :master})

      soa = Zone.SOA.new("ns1.minimal.com.", "admin.minimal.com.", 1,
        refresh: 3600,
        retry: 1800,
        expire: 604_800,
        minimum: 300
      )

      Storage.insert_record("minimal.com", "@", :SOA, soa, 3600)

      assert {:ok, [record], []} = Resolver.resolve("minimal.com", "@", :SOA)
      assert record.rdata.__struct__ == Zone.SOA

      assert {:nxdomain, [], authority} = Resolver.resolve("minimal.com", "www", :A)
      assert length(authority) == 1
    end
  end
end
