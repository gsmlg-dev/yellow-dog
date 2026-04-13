defmodule YellowDog.DnsProvider.Provider.IanaRootTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Provider.IanaRoot

  @sample_root_zone """
  ;       This file holds the information on root name servers needed to
  ;       initialize cache of Internet domain name servers
  .                        86400   IN  SOA     a.root-servers.net. nstld.verisign-grs.com. 2024091901 1800 900 604800 86400
  .                        518400  IN  NS      a.root-servers.net.
  .                        518400  IN  NS      b.root-servers.net.
  .                        518400  IN  NS      c.root-servers.net.
  a.root-servers.net.      518400  IN  A       198.41.0.4
  a.root-servers.net.      518400  IN  AAAA    2001:503:ba3e::2:30
  b.root-servers.net.      518400  IN  A       170.247.170.2
  b.root-servers.net.      518400  IN  AAAA    2801:1b8:10::b
  com.                     172800  IN  NS      a.gtld-servers.net.
  a.gtld-servers.net.      172800  IN  A       192.5.6.30
  """

  describe "init/1" do
    test "uses default URL when none provided" do
      assert {:ok, state} = IanaRoot.init(%{})
      assert state.url == "https://www.internic.net/domain/root.zone"
      assert state.cached_records == nil
      assert state.last_fetch == nil
    end

    test "accepts custom URL" do
      assert {:ok, state} = IanaRoot.init(%{url: "https://example.com/root.zone"})
      assert state.url == "https://example.com/root.zone"
    end
  end

  describe "list_zones/1" do
    test "returns single root zone" do
      {:ok, state} = IanaRoot.init(%{})
      assert {:ok, [%{name: ".", id: nil}], ^state} = IanaRoot.list_zones(state)
    end
  end

  describe "apply_changeset/3" do
    test "returns read_only error" do
      {:ok, state} = IanaRoot.init(%{})
      zone_ref = %{name: "."}
      changeset = %{additions: [], deletions: []}
      assert {:error, :read_only, ^state} = IanaRoot.apply_changeset(zone_ref, changeset, state)
    end
  end

  describe "parse_root_zone/1" do
    test "parses NS records" do
      records = IanaRoot.parse_root_zone(@sample_root_zone)
      ns_records = Enum.filter(records, &(&1.type == "NS"))

      assert length(ns_records) == 4

      root_ns = Enum.filter(ns_records, &(&1.owner == "."))
      assert length(root_ns) == 3

      assert Enum.any?(root_ns, fn r ->
               r.rdata == "a.root-servers.net." and r.ttl == 518_400
             end)
    end

    test "parses A records" do
      records = IanaRoot.parse_root_zone(@sample_root_zone)
      a_records = Enum.filter(records, &(&1.type == "A"))

      assert length(a_records) == 3
      assert Enum.any?(a_records, &(&1.rdata == "198.41.0.4"))
      assert Enum.any?(a_records, &(&1.rdata == "170.247.170.2"))
      assert Enum.any?(a_records, &(&1.rdata == "192.5.6.30"))
    end

    test "parses AAAA records" do
      records = IanaRoot.parse_root_zone(@sample_root_zone)
      aaaa_records = Enum.filter(records, &(&1.type == "AAAA"))

      assert length(aaaa_records) == 2
      assert Enum.any?(aaaa_records, &(&1.rdata == "2001:503:ba3e::2:30"))
    end

    test "skips SOA records" do
      records = IanaRoot.parse_root_zone(@sample_root_zone)
      soa_records = Enum.filter(records, &(&1.type == "SOA"))
      assert soa_records == []
    end

    test "skips comment lines" do
      records = IanaRoot.parse_root_zone(@sample_root_zone)
      # Comments should not produce any records
      refute Enum.any?(records, fn r -> String.starts_with?(r.owner, ";") end)
    end

    test "skips blank lines" do
      records = IanaRoot.parse_root_zone("\n\n\n")
      assert records == []
    end

    test "normalizes owner names with trailing dots" do
      records = IanaRoot.parse_root_zone(@sample_root_zone)

      Enum.each(records, fn r ->
        assert String.ends_with?(r.owner, "."),
               "Expected owner #{r.owner} to end with dot"
      end)
    end

    test "root zone owner is normalized to dot" do
      records = IanaRoot.parse_root_zone(@sample_root_zone)
      root_records = Enum.filter(records, &(&1.owner == "."))
      assert length(root_records) == 3
    end
  end

  describe "extract_soa_serial (via zone_serial)" do
    test "extracts serial from SOA line" do
      # zone_serial requires HTTP, so test the internal extract function
      # by calling parse on zone text with SOA
      serial = IanaRoot.extract_soa_serial(@sample_root_zone)
      assert serial == 2_024_091_901
    end

    test "returns 0 when no SOA present" do
      serial = IanaRoot.extract_soa_serial("com. 172800 IN NS a.gtld-servers.net.\n")
      assert serial == 0
    end
  end

  describe "get_records/2" do
    test "returns zone_not_found for non-root zone" do
      {:ok, state} = IanaRoot.init(%{})
      assert {:error, :zone_not_found, ^state} = IanaRoot.get_records(%{name: "com."}, state)
    end
  end

  describe "zone_serial/2" do
    test "returns zone_not_found for non-root zone" do
      {:ok, state} = IanaRoot.init(%{})
      assert {:error, :zone_not_found, ^state} = IanaRoot.zone_serial(%{name: "com."}, state)
    end
  end
end
