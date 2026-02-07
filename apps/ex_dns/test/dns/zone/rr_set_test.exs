defmodule DNS.Zone.RRSetTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Zone.RRSet.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/4 function with various parameters
  - TTL extraction from options
  - Edge cases and type validation
  """
  use ExUnit.Case, async: true

  alias DNS.Zone.RRSet
  alias DNS.Zone.Name
  alias DNS.ResourceRecordType, as: RRType

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(RRSet)
    end

    test "exports new/2" do
      Code.ensure_loaded!(RRSet)
      assert Kernel.function_exported?(RRSet, :new, 2)
    end

    test "exports new/3" do
      Code.ensure_loaded!(RRSet)
      assert Kernel.function_exported?(RRSet, :new, 3)
    end

    test "exports new/4" do
      Code.ensure_loaded!(RRSet)
      assert Kernel.function_exported?(RRSet, :new, 4)
    end

    test "defines a struct" do
      Code.ensure_loaded!(RRSet)
      assert is_struct(RRSet.__struct__())
    end
  end

  describe "struct fields" do
    test "has name field" do
      rrset = %RRSet{}
      assert Map.has_key?(rrset, :name)
    end

    test "has type field" do
      rrset = %RRSet{}
      assert Map.has_key?(rrset, :type)
    end

    test "has ttl field" do
      rrset = %RRSet{}
      assert Map.has_key?(rrset, :ttl)
    end

    test "has data field" do
      rrset = %RRSet{}
      assert Map.has_key?(rrset, :data)
    end

    test "has options field" do
      rrset = %RRSet{}
      assert Map.has_key?(rrset, :options)
    end

    test "default name is nil" do
      assert %RRSet{}.name == nil
    end

    test "default type is nil" do
      assert %RRSet{}.type == nil
    end

    test "default ttl is 0" do
      assert %RRSet{}.ttl == 0
    end

    test "default data is empty list" do
      assert %RRSet{}.data == []
    end

    test "default options is empty list" do
      assert %RRSet{}.options == []
    end
  end

  describe "new/2" do
    test "creates RRSet with name and type" do
      name = Name.new("example.com")
      type = RRType.new(:a)

      rrset = RRSet.new(name, type)

      assert is_struct(rrset, RRSet)
      assert rrset.name == name
      assert rrset.type == type
    end

    test "defaults data to empty list" do
      rrset = RRSet.new(Name.new("."), RRType.new(:ns))

      assert rrset.data == []
    end

    test "defaults options to empty list" do
      rrset = RRSet.new(Name.new("."), RRType.new(:ns))

      assert rrset.options == []
    end

    test "defaults ttl to 0" do
      rrset = RRSet.new(Name.new("."), RRType.new(:ns))

      assert rrset.ttl == 0
    end
  end

  describe "new/3" do
    test "creates RRSet with data" do
      name = Name.new(".")
      type = RRType.new(:ns)
      data = ["a.root-servers.net"]

      rrset = RRSet.new(name, type, data)

      assert rrset.data == data
    end

    test "accepts multiple data items" do
      name = Name.new(".")
      type = RRType.new(:ns)
      data = ["ns1.example.com", "ns2.example.com", "ns3.example.com"]

      rrset = RRSet.new(name, type, data)

      assert rrset.data == data
      assert length(rrset.data) == 3
    end

    test "accepts empty data list" do
      rrset = RRSet.new(Name.new("."), RRType.new(:a), [])

      assert rrset.data == []
    end
  end

  describe "new/4" do
    test "creates RRSet with options" do
      name = Name.new(".")
      type = RRType.new(:ns)
      data = ["a.root-servers.net"]
      options = [glues: [{"a.root-servers.net", {198, 41, 0, 4}}]]

      rrset = RRSet.new(name, type, data, options)

      assert rrset.options == options
    end

    test "extracts ttl from options" do
      rrset = RRSet.new(Name.new("."), RRType.new(:ns), [], ttl: 3600)

      assert rrset.ttl == 3600
      assert rrset.options == []
    end

    test "preserves other options after ttl extraction" do
      options = [ttl: 7200, glues: [], auth: true]

      rrset = RRSet.new(Name.new("."), RRType.new(:ns), [], options)

      assert rrset.ttl == 7200
      assert rrset.options == [glues: [], auth: true]
    end

    test "handles empty options list" do
      rrset = RRSet.new(Name.new("."), RRType.new(:ns), [], [])

      assert rrset.options == []
      assert rrset.ttl == 0
    end
  end

  describe "TTL handling" do
    test "ttl can be 0" do
      rrset = RRSet.new(Name.new("."), RRType.new(:a), [], ttl: 0)

      assert rrset.ttl == 0
    end

    test "ttl can be large value" do
      # Maximum TTL per spec is 2^31 - 1 (about 68 years)
      rrset = RRSet.new(Name.new("."), RRType.new(:a), [], ttl: 2_147_483_647)

      assert rrset.ttl == 2_147_483_647
    end

    test "ttl defaults to 0 when not in options" do
      rrset = RRSet.new(Name.new("."), RRType.new(:a), [], auth: true)

      assert rrset.ttl == 0
    end

    test "common TTL values work" do
      # 1 minute
      assert RRSet.new(Name.new("."), RRType.new(:a), [], ttl: 60).ttl == 60
      # 1 hour
      assert RRSet.new(Name.new("."), RRType.new(:a), [], ttl: 3600).ttl == 3600
      # 1 day
      assert RRSet.new(Name.new("."), RRType.new(:a), [], ttl: 86400).ttl == 86400
      # 1 week
      assert RRSet.new(Name.new("."), RRType.new(:a), [], ttl: 604_800).ttl == 604_800
    end
  end

  describe "DNS root zone RRSet" do
    test "creates root NS RRSet" do
      root = RRSet.new(Name.new("."), RRType.new(:ns), ["a.root-servers.net"], [])

      assert root.data == ["a.root-servers.net"]
      assert root.name == Name.new(".")
      assert root.type == RRType.new(:ns)
      assert root.options == []
      assert root.ttl == 0
    end

    test "creates root with multiple NS records" do
      servers = [
        "a.root-servers.net",
        "b.root-servers.net",
        "c.root-servers.net"
      ]

      root = RRSet.new(Name.new("."), RRType.new(:ns), servers, ttl: 3_600_000)

      assert length(root.data) == 3
      assert root.ttl == 3_600_000
    end

    test "creates root with glue records in options" do
      servers = ["a.root-servers.net"]

      glues = [
        [name: "a.root-servers.net.", type: RRType.new(:a), rdata: {198, 41, 0, 4}],
        [
          name: "a.root-servers.net.",
          type: RRType.new(:aaaa),
          rdata: {8193, 1283, 47678, 0, 0, 0, 2, 48}
        ]
      ]

      root = RRSet.new(Name.new("."), RRType.new(:ns), servers, ttl: 3_600_000, glues: glues)

      assert root.options[:glues] == glues
      assert root.ttl == 3_600_000
    end
  end

  describe "various record types" do
    test "creates A record RRSet" do
      rrset = RRSet.new(Name.new("www.example.com"), RRType.new(:a), [{192, 0, 2, 1}], ttl: 300)

      assert rrset.type == RRType.new(:a)
      assert rrset.data == [{192, 0, 2, 1}]
    end

    test "creates AAAA record RRSet" do
      rrset =
        RRSet.new(
          Name.new("www.example.com"),
          RRType.new(:aaaa),
          [{8193, 3512, 52232, 0, 0, 0, 0, 1}],
          ttl: 300
        )

      assert rrset.type == RRType.new(:aaaa)
    end

    test "creates MX record RRSet" do
      mx_data = [{10, "mail.example.com"}, {20, "mail2.example.com"}]

      rrset = RRSet.new(Name.new("example.com"), RRType.new(:mx), mx_data, ttl: 3600)

      assert rrset.type == RRType.new(:mx)
      assert length(rrset.data) == 2
    end

    test "creates TXT record RRSet" do
      txt_data = ["v=spf1 include:_spf.example.com ~all"]

      rrset = RRSet.new(Name.new("example.com"), RRType.new(:txt), txt_data, ttl: 3600)

      assert rrset.type == RRType.new(:txt)
      assert rrset.data == txt_data
    end

    test "creates SOA record RRSet" do
      soa_data = [
        %{
          mname: "ns1.example.com",
          rname: "admin.example.com",
          serial: 2024_010_101,
          refresh: 3600,
          retry: 900,
          expire: 604_800,
          minimum: 86400
        }
      ]

      rrset = RRSet.new(Name.new("example.com"), RRType.new(:soa), soa_data, ttl: 86400)

      assert rrset.type == RRType.new(:soa)
      assert length(rrset.data) == 1
    end

    test "creates CNAME record RRSet" do
      rrset =
        RRSet.new(
          Name.new("www.example.com"),
          RRType.new(:cname),
          ["www.example.com.cdn.cloudflare.net"],
          ttl: 300
        )

      assert rrset.type == RRType.new(:cname)
      assert length(rrset.data) == 1
    end

    test "creates SRV record RRSet" do
      srv_data = [
        {0, 5, 5060, "sip.example.com"},
        {10, 10, 5060, "sip2.example.com"}
      ]

      rrset = RRSet.new(Name.new("_sip._tcp.example.com"), RRType.new(:srv), srv_data, ttl: 3600)

      assert rrset.type == RRType.new(:srv)
      assert length(rrset.data) == 2
    end
  end

  describe "edge cases" do
    test "accepts any name value" do
      # Name as string
      rrset = RRSet.new("example.com", RRType.new(:a), [])
      assert rrset.name == "example.com"

      # Name as Name struct
      rrset = RRSet.new(Name.new("example.com"), RRType.new(:a), [])
      assert rrset.name == Name.new("example.com")
    end

    test "accepts any type value" do
      # Type as atom
      rrset = RRSet.new(Name.new("."), :ns, [])
      assert rrset.type == :ns

      # Type as RRType struct
      rrset = RRSet.new(Name.new("."), RRType.new(:ns), [])
      assert rrset.type == RRType.new(:ns)
    end

    test "accepts any data in list" do
      mixed_data = [
        "string",
        123,
        {1, 2, 3, 4},
        %{key: "value"},
        [:nested, :list]
      ]

      rrset = RRSet.new(Name.new("."), RRType.new(:txt), mixed_data, [])

      assert rrset.data == mixed_data
    end

    test "struct is inspectable" do
      rrset = RRSet.new(Name.new("example.com"), RRType.new(:a), [{192, 0, 2, 1}], ttl: 300)

      # Should not raise
      inspect_output = inspect(rrset)
      assert is_binary(inspect_output)
      assert inspect_output =~ "RRSet"
    end
  end
end
