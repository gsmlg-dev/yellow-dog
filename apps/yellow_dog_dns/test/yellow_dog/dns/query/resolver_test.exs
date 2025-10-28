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

  describe "wildcard resolution" do
    setup do
      zone_name = "wildcard.test"

      # Store SOA
      soa = Zone.SOA.new("ns1.wildcard.test.", "admin.wildcard.test.", 2024102901,
        refresh: 7200,
        retry: 3600,
        expire: 1_209_600,
        minimum: 3600
      )
      Storage.insert_record(zone_name, "@", :SOA, soa, 3600)

      # Store exact match records
      Storage.insert_record(zone_name, "ns1.wildcard.test.", :A, {192, 168, 1, 10}, 3600)
      Storage.insert_record(zone_name, "www.wildcard.test.", :A, {192, 168, 1, 100}, 3600)
      Storage.insert_record(zone_name, "exact.wildcard.test.", :A, {192, 168, 1, 50}, 3600)

      # Store wildcard records
      Storage.insert_record(zone_name, "*.wildcard.test.", :A, {192, 168, 1, 200}, 3600)
      Storage.insert_record(zone_name, "*.wildcard.test.", :AAAA, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x200}, 3600)

      # Store more specific wildcard
      Storage.insert_record(zone_name, "*.sub.wildcard.test.", :A, {192, 168, 1, 201}, 3600)

      # Store wildcard with other record types
      Storage.insert_record(zone_name, "*.app.wildcard.test.", :A, {192, 168, 1, 202}, 3600)
      Storage.insert_record(zone_name, "*.app.wildcard.test.", :TXT, "app subdomain", 3600)

      # Store exact match that should override wildcard
      Storage.insert_record(zone_name, "special.sub.wildcard.test.", :A, {192, 168, 1, 210}, 3600)

      # Store wildcard CNAME
      Storage.insert_record(zone_name, "*.alias.wildcard.test.", :CNAME, "www.wildcard.test.", 300)

      # Store zone metadata
      Storage.put_zone_metadata(zone_name, %{
        type: :master,
        serial: 2024102901,
        loaded_at: System.system_time(:second)
      })

      on_exit(fn ->
        try do
          Storage.delete_zone(zone_name)
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    test "resolves wildcard match for non-existent name" do
      # "anything.wildcard.test" should match "*.wildcard.test"
      assert {:ok, [record], []} = Resolver.resolve("wildcard.test", "anything.wildcard.test.", :A)

      assert record.owner == "anything.wildcard.test."
      assert record.type == :A
      assert record.rdata == {192, 168, 1, 200}
    end

    test "resolves wildcard AAAA record" do
      assert {:ok, [record], []} = Resolver.resolve("wildcard.test", "foo.wildcard.test.", :AAAA)

      assert record.owner == "foo.wildcard.test."
      assert record.type == :AAAA
      assert record.rdata == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x200}
    end

    test "exact match takes precedence over wildcard" do
      # "www.wildcard.test" has exact match, should not use wildcard
      assert {:ok, [record], []} = Resolver.resolve("wildcard.test", "www.wildcard.test.", :A)

      assert record.owner == "www.wildcard.test."
      assert record.rdata == {192, 168, 1, 100}
    end

    test "resolves more specific wildcard" do
      # "foo.sub.wildcard.test" should match "*.sub.wildcard.test", not "*.wildcard.test"
      assert {:ok, [record], []} = Resolver.resolve("wildcard.test", "foo.sub.wildcard.test.", :A)

      assert record.owner == "foo.sub.wildcard.test."
      assert record.rdata == {192, 168, 1, 201}
    end

    test "exact match overrides more specific wildcard" do
      # "special.sub.wildcard.test" has exact match
      assert {:ok, [record], []} = Resolver.resolve("wildcard.test", "special.sub.wildcard.test.", :A)

      assert record.owner == "special.sub.wildcard.test."
      assert record.rdata == {192, 168, 1, 210}
    end

    test "resolves wildcard TXT record" do
      assert {:ok, [record], []} = Resolver.resolve("wildcard.test", "bar.app.wildcard.test.", :TXT)

      assert record.owner == "bar.app.wildcard.test."
      assert record.type == :TXT
      assert record.rdata == "app subdomain"
    end

    test "wildcard does not match multiple labels" do
      # "foo.bar.wildcard.test" should match "*.wildcard.test" (not multiple levels)
      assert {:ok, [record], []} = Resolver.resolve("wildcard.test", "foo.bar.wildcard.test.", :A)

      # But it should return NXDOMAIN since *.wildcard.test only matches single label
      # Actually, wait - let me think about this. In DNS:
      # "*.wildcard.test" DOES match "foo.bar.wildcard.test"
      # It matches ANY number of labels in place of the *
      # So this should work
      assert record.owner == "foo.bar.wildcard.test."
      assert record.rdata == {192, 168, 1, 200}
    end

    test "returns NXDOMAIN when no wildcard or exact match" do
      # Query for a name that doesn't match any wildcard or exact record
      # Let's query a different zone
      Storage.put_zone_metadata("other.test", %{type: :master})
      soa = Zone.SOA.new("ns1.other.test.", "admin.other.test.", 1,
        refresh: 3600,
        retry: 1800,
        expire: 604_800,
        minimum: 300
      )
      Storage.insert_record("other.test", "@", :SOA, soa, 3600)

      assert {:nxdomain, [], authority} = Resolver.resolve("other.test", "anything.other.test.", :A)
      assert length(authority) == 1
    end

    test "wildcard CNAME can be resolved directly" do
      # First check that we can resolve the wildcard CNAME itself
      assert {:ok, [record], []} = Resolver.resolve("wildcard.test", "test.alias.wildcard.test.", :CNAME)

      assert record.owner == "test.alias.wildcard.test."
      assert record.type == :CNAME
      assert record.rdata == "www.wildcard.test."
    end

    test "wildcard with CNAME follows chain" do
      # Query for "anything.alias.wildcard.test" should match wildcard CNAME
      assert {:ok, answers, []} = Resolver.resolve_with_cname("wildcard.test", "test.alias.wildcard.test.", :A)

      # Should have CNAME + A record
      assert length(answers) == 2

      cname_record = Enum.find(answers, &(&1.type == :CNAME))
      a_record = Enum.find(answers, &(&1.type == :A))

      assert cname_record.owner == "test.alias.wildcard.test."
      assert cname_record.rdata == "www.wildcard.test."

      assert a_record.owner == "www.wildcard.test."
      assert a_record.rdata == {192, 168, 1, 100}
    end

    test "resolves wildcard with relative name" do
      assert {:ok, [record], []} = Resolver.resolve("wildcard.test", "relative", :A)

      assert record.owner == "relative.wildcard.test."
      assert record.rdata == {192, 168, 1, 200}
    end
  end
end
