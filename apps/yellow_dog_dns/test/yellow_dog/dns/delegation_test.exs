defmodule YellowDog.Dns.Query.DelegationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Query.Delegation
  alias YellowDog.Dns.Zone
  alias YellowDog.Dns.Zone.Manager
  alias YellowDog.Dns.Zone.Parser

  setup do
    # Initialize Zone Storage ETS tables if needed
    case YellowDog.Dns.Zone.Storage.init() do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end

    # Start Zone Manager for testing
    {:ok, _pid} = start_supervised(Manager)

    # Load a test zone with delegations
    zone_data = """
    $ORIGIN example.com.
    $TTL 3600
    @       IN  SOA   ns1.example.com. admin.example.com. (
                      2024102801 ; Serial
                      7200       ; Refresh
                      3600       ; Retry
                      1209600    ; Expire
                      3600 )     ; Minimum

    @       IN  NS    ns1.example.com.
    @       IN  NS    ns2.example.com.
    ns1     IN  A     192.0.2.1
    ns2     IN  A     192.0.2.2

    ; Main zone records
    www     IN  A     192.0.2.10
    mail    IN  A     192.0.2.20

    ; Sub-zone delegation with in-bailiwick nameservers
    sub     IN  NS    ns1.sub.example.com.
    sub     IN  NS    ns2.sub.example.com.
    ns1.sub IN  A     192.0.2.100
    ns2.sub IN  A     192.0.2.101

    ; Another sub-zone with out-of-bailiwick nameserver
    another IN  NS    ns1.external.net.
    another IN  NS    ns2.sub.example.com.
    ns2.sub IN  A     192.0.2.102

    ; Deep sub-zone delegation
    deep.sub IN  NS    ns1.deep.sub.example.com.
    ns1.deep.sub IN A  192.0.2.200
    """

    {:ok, zone} = Parser.parse_string(zone_data, zone_name: "example.com")
    {:ok, _} = Manager.load_zone_data("example.com", zone)

    :ok
  end

  describe "check_delegation/3" do
    test "detects delegation for sub-zone query" do
      # Debug: Check what records are in the zone
      all_records = :ets.tab2list(:dns_zone_data)

      zone_records =
        Enum.filter(all_records, fn
          {{"example.com", _owner, _type}, _data} -> true
          _ -> false
        end)

      IO.puts("\nTotal zone records: #{length(zone_records)}")

      ns_records =
        Enum.filter(zone_records, fn
          {{"example.com", owner, :NS}, _data} ->
            IO.puts("  NS: owner=#{inspect(owner)}")
            true

          _ ->
            false
        end)

      IO.puts("NS record count: #{length(ns_records)}\n")

      # Query for www.sub.example.com should be delegated to sub.example.com
      result = Delegation.check_delegation("example.com", "www.sub.example.com", :A)

      assert {:delegated, delegation_point, ns_records, glue_records} = result
      assert delegation_point == "sub.example.com"
      assert length(ns_records) == 2
      assert length(glue_records) == 2

      # Verify NS records
      ns_hostnames = Enum.map(ns_records, & &1.rdata)
      assert "ns1.sub.example.com" in ns_hostnames
      assert "ns2.sub.example.com" in ns_hostnames

      # Verify glue records (both in-bailiwick)
      glue_names = Enum.map(glue_records, & &1.owner)
      assert "ns1.sub.example.com" in glue_names
      assert "ns2.sub.example.com" in glue_names
    end

    test "detects delegation for deep sub-zone" do
      # Query for www.deep.sub.example.com should be delegated to deep.sub.example.com
      result = Delegation.check_delegation("example.com", "www.deep.sub.example.com", :A)

      assert {:delegated, delegation_point, ns_records, glue_records} = result
      assert delegation_point == "deep.sub.example.com"
      assert length(ns_records) == 1
      assert length(glue_records) == 1

      assert hd(ns_records).rdata == "ns1.deep.sub.example.com"
      assert hd(glue_records).owner == "ns1.deep.sub.example.com"
    end

    test "does not delegate for zone apex query" do
      # Query for example.com itself is not delegated
      result = Delegation.check_delegation("example.com", "example.com", :A)
      assert result == :not_delegated
    end

    test "does not delegate for records in parent zone" do
      # Query for www.example.com (in parent zone) is not delegated
      result = Delegation.check_delegation("example.com", "www.example.com", :A)
      assert result == :not_delegated
    end

    test "does not delegate NS query at zone apex" do
      # NS query at zone apex should not be treated as delegation
      result = Delegation.check_delegation("example.com", "example.com", :NS)
      assert result == :not_delegated
    end

    test "handles mixed in-bailiwick and out-of-bailiwick nameservers" do
      # another.example.com has one out-of-bailiwick NS
      result = Delegation.check_delegation("example.com", "www.another.example.com", :A)

      assert {:delegated, "another.example.com", ns_records, glue_records} = result
      assert length(ns_records) == 2

      # Only in-bailiwick NS should have glue
      glue_names = Enum.map(glue_records, & &1.owner)
      assert "ns2.sub.example.com" in glue_names
      refute "ns1.external.net" in glue_names
    end
  end

  describe "find_delegation_point/2" do
    test "finds closest delegation point" do
      result = Delegation.find_delegation_point("example.com", "a.b.c.sub.example.com")
      assert result == {:ok, "sub.example.com"}
    end

    test "returns not_found for non-delegated name" do
      result = Delegation.find_delegation_point("example.com", "www.example.com")
      assert result == :not_found
    end

    test "finds deep delegation before shallow" do
      # Should find deep.sub.example.com before sub.example.com
      result = Delegation.find_delegation_point("example.com", "www.deep.sub.example.com")
      assert result == {:ok, "deep.sub.example.com"}
    end
  end

  describe "get_ns_records/2" do
    test "retrieves NS records for delegation" do
      {:ok, ns_records} = Delegation.get_ns_records("example.com", "sub.example.com")

      assert length(ns_records) == 2
      assert Enum.all?(ns_records, fn r -> r.type == :NS end)

      ns_hostnames = Enum.map(ns_records, & &1.rdata)
      assert "ns1.sub.example.com" in ns_hostnames
      assert "ns2.sub.example.com" in ns_hostnames
    end

    test "returns empty list for non-existent delegation" do
      {:ok, ns_records} = Delegation.get_ns_records("example.com", "nonexistent.example.com")
      assert ns_records == []
    end
  end

  describe "get_glue_records/3" do
    test "returns glue for in-bailiwick nameservers" do
      ns_records = [
        %Zone.Record{
          owner: "sub.example.com",
          type: :NS,
          class: :IN,
          ttl: 3600,
          rdata: "ns1.sub.example.com"
        },
        %Zone.Record{
          owner: "sub.example.com",
          type: :NS,
          class: :IN,
          ttl: 3600,
          rdata: "ns2.sub.example.com"
        }
      ]

      glue = Delegation.get_glue_records("example.com", "sub.example.com", ns_records)

      assert length(glue) == 2
      assert Enum.all?(glue, fn r -> r.type == :A end)

      glue_names = Enum.map(glue, & &1.owner)
      assert "ns1.sub.example.com" in glue_names
      assert "ns2.sub.example.com" in glue_names
    end

    test "does not return glue for out-of-bailiwick nameservers" do
      ns_records = [
        %Zone.Record{
          owner: "another.example.com",
          type: :NS,
          class: :IN,
          ttl: 3600,
          rdata: "ns1.external.net"
        }
      ]

      glue = Delegation.get_glue_records("example.com", "another.example.com", ns_records)

      # No glue for out-of-bailiwick
      assert glue == []
    end
  end

  describe "integration with Query.Resolver" do
    test "resolver returns delegation result for sub-zone query" do
      alias YellowDog.Dns.Query.Resolver

      result = Resolver.resolve("example.com", "www.sub.example.com", :A)

      assert {:delegation, ns_records, glue_records} = result
      assert length(ns_records) == 2
      assert length(glue_records) == 2
    end

    test "resolver returns normal answer for parent zone query" do
      alias YellowDog.Dns.Query.Resolver

      result = Resolver.resolve("example.com", "www.example.com", :A)

      assert {:ok, answers, []} = result
      assert length(answers) == 1
      assert hd(answers).type == :A
    end
  end
end
