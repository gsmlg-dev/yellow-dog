defmodule DNS.Zone.RootHintTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Zone.RootHint.

  Tests cover:
  - Module structure and exports
  - Root hints data loading and parsing
  - Nameserver extraction and glue record association
  - Data directory and file access
  - Link references for IANA resources
  """
  use ExUnit.Case, async: true

  alias DNS.ResourceRecordType, as: RRType
  alias DNS.Zone.RootHint
  alias DNS.Zone.RRSet
  alias DNS.Zone.Name

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(RootHint)
    end

    test "exports root_hints/0" do
      Code.ensure_loaded!(RootHint)
      assert Kernel.function_exported?(RootHint, :root_hints, 0)
    end

    test "exports nameservers/0" do
      Code.ensure_loaded!(RootHint)
      assert Kernel.function_exported?(RootHint, :nameservers, 0)
    end

    test "exports root_hints_text/0" do
      Code.ensure_loaded!(RootHint)
      assert Kernel.function_exported?(RootHint, :root_hints_text, 0)
    end

    test "exports links/0" do
      Code.ensure_loaded!(RootHint)
      assert Kernel.function_exported?(RootHint, :links, 0)
    end

    test "exports data_dir/0" do
      Code.ensure_loaded!(RootHint)
      assert Kernel.function_exported?(RootHint, :data_dir, 0)
    end
  end

  describe "data_dir/0" do
    test "returns a valid path" do
      dir = RootHint.data_dir()

      assert is_binary(dir)
      assert dir =~ "priv"
      assert dir =~ "data"
    end

    test "directory exists" do
      dir = RootHint.data_dir()

      assert File.exists?(dir)
      assert File.dir?(dir)
    end
  end

  describe "links/0" do
    test "returns a keyword list" do
      links = RootHint.links()

      assert is_list(links)
      assert Keyword.keyword?(links)
    end

    test "contains root_hints URL" do
      links = RootHint.links()

      assert Keyword.has_key?(links, :root_hints)
      assert links[:root_hints] == "https://www.internic.net/domain/named.root"
    end

    test "contains root_zone URL" do
      links = RootHint.links()

      assert Keyword.has_key?(links, :root_zone)
      assert links[:root_zone] == "https://www.internic.net/domain/root.zone"
    end

    test "contains root_trust_anchor information" do
      links = RootHint.links()

      assert Keyword.has_key?(links, :root_trust_anchor)
      trust_anchor = links[:root_trust_anchor]
      assert is_list(trust_anchor)
      assert Keyword.has_key?(trust_anchor, :url)
      assert Keyword.has_key?(trust_anchor, :xml)
    end

    test "contains top_level_domains URL" do
      links = RootHint.links()

      assert Keyword.has_key?(links, :top_level_domains)
      assert String.starts_with?(links[:top_level_domains], "https://data.iana.org/TLD/")
    end
  end

  describe "root_hints_text/0" do
    test "returns non-empty string" do
      text = RootHint.root_hints_text()

      assert is_binary(text)
      assert String.length(text) > 0
    end

    test "contains root server entries" do
      text = RootHint.root_hints_text()

      # Root hints file should contain root server names (case-insensitive)
      assert String.upcase(text) =~ "ROOT-SERVERS.NET"
    end

    test "contains NS records" do
      text = RootHint.root_hints_text()

      assert text =~ "NS"
    end

    test "contains A records" do
      text = RootHint.root_hints_text()

      assert text =~ " A "
    end

    test "contains AAAA records" do
      text = RootHint.root_hints_text()

      assert text =~ "AAAA"
    end
  end

  describe "root_hints/0" do
    test "returns list of resource records" do
      root_hints = RootHint.root_hints()

      assert is_list(root_hints)
      assert length(root_hints) > 0
    end

    test "each record has required fields" do
      root_hints = RootHint.root_hints()

      Enum.each(root_hints, fn record ->
        assert Keyword.has_key?(record, :name)
        assert Keyword.has_key?(record, :ttl)
        assert Keyword.has_key?(record, :type)
        assert Keyword.has_key?(record, :rdata)
      end)
    end

    test "contains 13 NS records for root zone" do
      root_hints = RootHint.root_hints()

      ns_records =
        root_hints
        |> Enum.filter(fn record ->
          record[:type] == RRType.new(:ns) and record[:name] == "."
        end)

      # There are 13 root servers (a through m)
      assert length(ns_records) == 13
    end

    test "NS records have valid TTL" do
      root_hints = RootHint.root_hints()

      ns_records =
        root_hints
        |> Enum.filter(fn record -> record[:type] == RRType.new(:ns) end)

      Enum.each(ns_records, fn record ->
        assert is_integer(record[:ttl])
        assert record[:ttl] > 0
      end)
    end

    test "A records have valid IPv4 addresses" do
      root_hints = RootHint.root_hints()

      a_records =
        root_hints
        |> Enum.filter(fn record -> record[:type] == RRType.new(:a) end)

      assert length(a_records) > 0

      Enum.each(a_records, fn record ->
        rdata = record[:rdata]
        assert is_tuple(rdata)
        assert tuple_size(rdata) == 4

        # Each octet should be 0-255
        {a, b, c, d} = rdata
        assert a >= 0 and a <= 255
        assert b >= 0 and b <= 255
        assert c >= 0 and c <= 255
        assert d >= 0 and d <= 255
      end)
    end

    test "AAAA records have valid IPv6 addresses" do
      root_hints = RootHint.root_hints()

      aaaa_records =
        root_hints
        |> Enum.filter(fn record -> record[:type] == RRType.new(:aaaa) end)

      assert length(aaaa_records) > 0

      Enum.each(aaaa_records, fn record ->
        rdata = record[:rdata]
        assert is_tuple(rdata)
        assert tuple_size(rdata) == 8

        # Each segment should be 0-65535
        Tuple.to_list(rdata)
        |> Enum.each(fn segment ->
          assert segment >= 0 and segment <= 65535
        end)
      end)
    end

    test "contains A records for all 13 root servers" do
      root_hints = RootHint.root_hints()

      a_records =
        root_hints
        |> Enum.filter(fn record -> record[:type] == RRType.new(:a) end)

      # Each root server (a through m) should have an A record
      server_names =
        a_records
        |> Enum.map(fn record -> record[:name] end)
        |> Enum.uniq()

      assert length(server_names) == 13

      # Verify all server names follow the pattern (case-insensitive)
      Enum.each(server_names, fn name ->
        assert String.ends_with?(String.upcase(name), "ROOT-SERVERS.NET.")
      end)
    end

    test "contains AAAA records for root servers" do
      root_hints = RootHint.root_hints()

      aaaa_records =
        root_hints
        |> Enum.filter(fn record -> record[:type] == RRType.new(:aaaa) end)

      # All 13 root servers have IPv6 addresses
      server_names =
        aaaa_records
        |> Enum.map(fn record -> record[:name] end)
        |> Enum.uniq()

      assert length(server_names) == 13
    end

    test "can construct RRSet from NS records" do
      root_hints = RootHint.root_hints()

      ns_list =
        root_hints
        |> Enum.filter(fn rr ->
          rr[:type] == RRType.new(:ns) and rr[:name] == "."
        end)

      rrset = RRSet.new(Name.new("."), RRType.new(:ns), ns_list |> Enum.map(& &1[:rdata]), [])

      assert is_struct(rrset, RRSet)
      assert length(rrset.data) == 13
    end

    test "can associate glue records with NS records" do
      root_hints = RootHint.root_hints()

      ns_list =
        root_hints
        |> Enum.filter(fn rr ->
          rr[:type] == RRType.new(:ns) and rr[:name] == "."
        end)

      rrset = RRSet.new(Name.new("."), RRType.new(:ns), ns_list |> Enum.map(& &1[:rdata]), [])

      glues =
        rrset.data
        |> Enum.reduce([], fn d, list ->
          glue_records =
            root_hints
            |> Enum.filter(fn rr ->
              rr[:name] == to_string(d)
            end)

          list ++ glue_records
        end)

      rrset_with_glues = %{rrset | options: [glues: glues]}

      assert is_struct(rrset_with_glues, RRSet)
      assert length(rrset_with_glues.options[:glues]) > 0
    end
  end

  describe "nameservers/0" do
    test "returns a map" do
      nameservers = RootHint.nameservers()

      assert is_map(nameservers)
    end

    test "contains 13 root servers" do
      nameservers = RootHint.nameservers()

      assert map_size(nameservers) == 13
    end

    test "each entry has name, ipv4, and ipv6 fields" do
      nameservers = RootHint.nameservers()

      Enum.each(nameservers, fn {key, value} ->
        assert is_binary(key)
        # Server names are uppercase in the data file
        assert String.ends_with?(String.upcase(key), "ROOT-SERVERS.NET.")
        assert is_map(value)
        assert Map.has_key?(value, :name)
        assert Map.has_key?(value, :ipv4)
        assert Map.has_key?(value, :ipv6)
      end)
    end

    test "each server has at least one IPv4 address" do
      nameservers = RootHint.nameservers()

      Enum.each(nameservers, fn {_key, value} ->
        assert is_list(value.ipv4)
        assert length(value.ipv4) >= 1
      end)
    end

    test "each server has at least one IPv6 address" do
      nameservers = RootHint.nameservers()

      Enum.each(nameservers, fn {_key, value} ->
        assert is_list(value.ipv6)
        assert length(value.ipv6) >= 1
      end)
    end

    test "contains A.ROOT-SERVERS.NET" do
      nameservers = RootHint.nameservers()

      # Server names are uppercase in the data file
      assert Map.has_key?(nameservers, "A.ROOT-SERVERS.NET.")
      a_server = nameservers["A.ROOT-SERVERS.NET."]

      # a.root-servers.net has IP 198.41.0.4
      assert {198, 41, 0, 4} in a_server.ipv4
    end

    test "IPv4 addresses are valid tuples" do
      nameservers = RootHint.nameservers()

      Enum.each(nameservers, fn {_key, value} ->
        Enum.each(value.ipv4, fn ip ->
          assert is_tuple(ip)
          assert tuple_size(ip) == 4
        end)
      end)
    end

    test "IPv6 addresses are valid tuples" do
      nameservers = RootHint.nameservers()

      Enum.each(nameservers, fn {_key, value} ->
        Enum.each(value.ipv6, fn ip ->
          assert is_tuple(ip)
          assert tuple_size(ip) == 8
        end)
      end)
    end
  end

  describe "root server data correctness" do
    # These tests verify specific well-known root server data
    # Server names are uppercase in the data file

    test "A.ROOT-SERVERS.NET has correct IPv4" do
      nameservers = RootHint.nameservers()
      a = nameservers["A.ROOT-SERVERS.NET."]

      assert {198, 41, 0, 4} in a.ipv4
    end

    test "B.ROOT-SERVERS.NET has correct IPv4" do
      nameservers = RootHint.nameservers()
      b = nameservers["B.ROOT-SERVERS.NET."]

      assert {170, 247, 170, 2} in b.ipv4
    end

    test "F.ROOT-SERVERS.NET has correct IPv4" do
      nameservers = RootHint.nameservers()
      f = nameservers["F.ROOT-SERVERS.NET."]

      assert {192, 5, 5, 241} in f.ipv4
    end

    test "K.ROOT-SERVERS.NET has correct IPv4" do
      nameservers = RootHint.nameservers()
      k = nameservers["K.ROOT-SERVERS.NET."]

      assert {193, 0, 14, 129} in k.ipv4
    end

    test "M.ROOT-SERVERS.NET has correct IPv4" do
      nameservers = RootHint.nameservers()
      m = nameservers["M.ROOT-SERVERS.NET."]

      assert {202, 12, 27, 33} in m.ipv4
    end

    test "all server letters are present (A through M)" do
      nameservers = RootHint.nameservers()

      expected_servers =
        ?A..?M
        |> Enum.map(fn char -> "#{<<char>>}.ROOT-SERVERS.NET." end)

      Enum.each(expected_servers, fn server ->
        assert Map.has_key?(nameservers, server),
               "Missing root server: #{server}"
      end)
    end
  end
end
