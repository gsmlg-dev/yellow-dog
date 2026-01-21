defmodule DNS.Message.Record.Data.ATest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.A.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with IPv4 address tuples
  - from_iodata/1, from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 1035)
  - Edge cases and special addresses
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.A

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(A)
    end

    test "exports new/1" do
      Code.ensure_loaded!(A)
      assert Kernel.function_exported?(A, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(A)
      assert Kernel.function_exported?(A, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(A)
      assert Kernel.function_exported?(A, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(A)
      assert is_struct(A.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %A{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %A{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %A{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %A{}
      assert Map.has_key?(record, :data)
    end

    test "default rdlength is 4" do
      assert %A{}.rdlength == 4
    end

    test "default type is A (1)" do
      type = %A{}.type
      assert type == DNS.ResourceRecordType.new(1)
    end

    test "default raw is nil" do
      assert %A{}.raw == nil
    end

    test "default data is nil" do
      assert %A{}.data == nil
    end
  end

  describe "new/1" do
    test "creates A record from IPv4 tuple" do
      {:ok, ip} = :inet.parse_ipv4_address(~c"192.168.1.1")
      record = A.new(ip)
      assert %A{} = record
      assert record.data == ip
    end

    test "stores raw binary" do
      record = A.new({192, 168, 1, 1})
      assert record.raw == <<192, 168, 1, 1>>
    end

    test "creates record for localhost" do
      record = A.new({127, 0, 0, 1})
      assert record.data == {127, 0, 0, 1}
    end

    test "creates record for Cloudflare DNS" do
      record = A.new({1, 1, 1, 1})
      assert record.data == {1, 1, 1, 1}
    end

    test "creates record for Google DNS" do
      record = A.new({8, 8, 8, 8})
      assert record.data == {8, 8, 8, 8}
    end

    test "creates record for broadcast address" do
      record = A.new({255, 255, 255, 255})
      assert record.data == {255, 255, 255, 255}
    end

    test "creates record for zero address" do
      record = A.new({0, 0, 0, 0})
      assert record.data == {0, 0, 0, 0}
    end

    test "creates record for private network 10.x" do
      record = A.new({10, 0, 0, 1})
      assert record.data == {10, 0, 0, 1}
    end

    test "creates record for private network 172.16.x" do
      record = A.new({172, 16, 0, 1})
      assert record.data == {172, 16, 0, 1}
    end

    test "creates record for private network 192.168.x" do
      record = A.new({192, 168, 1, 100})
      assert record.data == {192, 168, 1, 100}
    end
  end

  describe "from_iodata/1" do
    test "parses 4-byte binary" do
      record = A.from_iodata(<<192, 168, 1, 1>>)
      assert %A{} = record
      assert record.data == {192, 168, 1, 1}
    end

    test "stores raw binary" do
      raw = <<10, 0, 0, 1>>
      record = A.from_iodata(raw)
      assert record.raw == raw
    end

    test "parses localhost" do
      record = A.from_iodata(<<127, 0, 0, 1>>)
      assert record.data == {127, 0, 0, 1}
    end

    test "parses broadcast address" do
      record = A.from_iodata(<<255, 255, 255, 255>>)
      assert record.data == {255, 255, 255, 255}
    end

    test "parses zero address" do
      record = A.from_iodata(<<0, 0, 0, 0>>)
      assert record.data == {0, 0, 0, 0}
    end
  end

  describe "from_iodata/2" do
    test "accepts message parameter (ignored)" do
      record = A.from_iodata(<<192, 168, 1, 1>>, <<>>)
      assert record.data == {192, 168, 1, 1}
    end

    test "message can be nil" do
      record = A.from_iodata(<<8, 8, 8, 8>>, nil)
      assert record.data == {8, 8, 8, 8}
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats IPv4 address correctly" do
      record = A.new({192, 168, 1, 1})
      assert to_string(record) == "192.168.1.1"
    end

    test "formats localhost" do
      record = A.new({127, 0, 0, 1})
      assert to_string(record) == "127.0.0.1"
    end

    test "formats Cloudflare DNS" do
      record = A.new({1, 1, 1, 1})
      assert to_string(record) == "1.1.1.1"
    end

    test "formats Google DNS" do
      record = A.new({8, 8, 8, 8})
      assert to_string(record) == "8.8.8.8"
    end

    test "formats broadcast address" do
      record = A.new({255, 255, 255, 255})
      assert to_string(record) == "255.255.255.255"
    end

    test "formats zero address" do
      record = A.new({0, 0, 0, 0})
      assert to_string(record) == "0.0.0.0"
    end

    test "string interpolation works" do
      record = A.new({192, 168, 0, 1})
      assert "IP: #{record}" == "IP: 192.168.0.1"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      record = A.new({192, 168, 1, 1})
      iodata = DNS.Parameter.to_iodata(record)
      # A record wire format: 2-byte length (4) + 4-byte IP
      assert iodata == <<4::16, 192, 168, 1, 1>>
    end

    test "wire format has 6 bytes total" do
      record = A.new({10, 0, 0, 1})
      iodata = DNS.Parameter.to_iodata(record)
      assert byte_size(iodata) == 6
    end

    test "length prefix is always 4" do
      record = A.new({1, 2, 3, 4})
      <<length::16, _rest::binary>> = DNS.Parameter.to_iodata(record)
      assert length == 4
    end

    test "IP bytes follow length" do
      record = A.new({192, 168, 100, 200})
      <<4::16, a, b, c, d>> = DNS.Parameter.to_iodata(record)
      assert {a, b, c, d} == {192, 168, 100, 200}
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      original_ip = {192, 168, 1, 100}
      record = A.new(original_ip)
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      parsed = A.from_iodata(raw)
      assert parsed.data == original_ip
    end

    test "from_iodata -> to_string -> parse" do
      raw = <<10, 20, 30, 40>>
      record = A.from_iodata(raw)
      str = to_string(record)
      {:ok, parsed_ip} = :inet.parse_ipv4_address(String.to_charlist(str))
      assert parsed_ip == {10, 20, 30, 40}
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = A.new({192, 168, 1, 1})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "all octets at boundary values" do
      record = A.new({0, 128, 255, 1})
      assert record.data == {0, 128, 255, 1}
      assert to_string(record) == "0.128.255.1"
    end

    test "rdlength is always 4" do
      record = A.new({192, 168, 1, 1})
      assert record.rdlength == 4
    end
  end

  describe "RFC compliance" do
    test "A record type value is 1 per RFC 1035" do
      record = A.new({192, 168, 1, 1})
      # RFC 1035 Section 3.2.2: A = 1
      # type.value is binary <<0, 1>> representing 16-bit value
      assert record.type.value == <<0, 1>>
    end

    test "rdlength is 4 bytes per RFC 1035" do
      record = A.new({192, 168, 1, 1})
      # RFC 1035 Section 3.4.1: A RDATA is 4-octet Internet address
      assert record.rdlength == 4
    end

    test "wire format uses network byte order (big-endian)" do
      record = A.new({192, 168, 1, 1})
      <<_length::16, a, b, c, d>> = DNS.Parameter.to_iodata(record)
      # Octets are in order: first octet first
      assert {a, b, c, d} == {192, 168, 1, 1}
    end
  end

  describe "special IPv4 addresses" do
    test "creates record for loopback range (127.x.x.x)" do
      loopback_addrs = [
        {127, 0, 0, 1},
        {127, 0, 0, 2},
        {127, 255, 255, 255}
      ]

      for addr <- loopback_addrs do
        record = A.new(addr)
        assert record.data == addr
      end
    end

    test "creates record for link-local range (169.254.x.x)" do
      record = A.new({169, 254, 0, 1})
      assert record.data == {169, 254, 0, 1}
    end

    test "creates record for multicast range (224-239.x.x.x)" do
      multicast_addrs = [
        {224, 0, 0, 1},    # All hosts
        {224, 0, 0, 251},  # mDNS
        {239, 255, 255, 250}  # SSDP
      ]

      for addr <- multicast_addrs do
        record = A.new(addr)
        assert record.data == addr
      end
    end

    test "creates record for reserved range (240-255.x.x.x)" do
      record = A.new({240, 0, 0, 1})
      assert record.data == {240, 0, 0, 1}
    end

    test "creates record for documentation range (192.0.2.x)" do
      # TEST-NET-1 per RFC 5737
      record = A.new({192, 0, 2, 1})
      assert record.data == {192, 0, 2, 1}
    end

    test "creates record for second documentation range (198.51.100.x)" do
      # TEST-NET-2 per RFC 5737
      record = A.new({198, 51, 100, 1})
      assert record.data == {198, 51, 100, 1}
    end

    test "creates record for third documentation range (203.0.113.x)" do
      # TEST-NET-3 per RFC 5737
      record = A.new({203, 0, 113, 1})
      assert record.data == {203, 0, 113, 1}
    end
  end

  describe "well-known DNS servers" do
    test "creates record for Cloudflare DNS servers" do
      cloudflare_dns = [
        {1, 1, 1, 1},
        {1, 0, 0, 1}
      ]

      for addr <- cloudflare_dns do
        record = A.new(addr)
        assert record.data == addr
      end
    end

    test "creates record for Google DNS servers" do
      google_dns = [
        {8, 8, 8, 8},
        {8, 8, 4, 4}
      ]

      for addr <- google_dns do
        record = A.new(addr)
        assert record.data == addr
      end
    end

    test "creates record for Quad9 DNS servers" do
      quad9_dns = [
        {9, 9, 9, 9},
        {149, 112, 112, 112}
      ]

      for addr <- quad9_dns do
        record = A.new(addr)
        assert record.data == addr
      end
    end

    test "creates record for OpenDNS servers" do
      opendns = [
        {208, 67, 222, 222},
        {208, 67, 220, 220}
      ]

      for addr <- opendns do
        record = A.new(addr)
        assert record.data == addr
      end
    end
  end

  describe "type field" do
    test "type field is DNS.ResourceRecordType struct" do
      record = A.new({192, 168, 1, 1})
      assert %DNS.ResourceRecordType{} = record.type
    end

    test "type can be compared with new type" do
      record = A.new({192, 168, 1, 1})
      a_type = DNS.ResourceRecordType.new(:a)
      assert record.type == a_type
    end

    test "type can be compared by value" do
      record = A.new({192, 168, 1, 1})
      # Value is 16-bit binary representation
      assert record.type.value == <<0, 1>>
    end
  end

  describe "data field" do
    test "data is 4-tuple of integers" do
      record = A.new({192, 168, 1, 1})
      assert is_tuple(record.data)
      assert tuple_size(record.data) == 4
    end

    test "data tuple values are 0-255" do
      record = A.new({192, 168, 1, 1})
      {a, b, c, d} = record.data
      assert a >= 0 and a <= 255
      assert b >= 0 and b <= 255
      assert c >= 0 and c <= 255
      assert d >= 0 and d <= 255
    end
  end

  describe "raw field" do
    test "raw field is 4-byte binary" do
      record = A.new({192, 168, 1, 1})
      assert is_binary(record.raw)
      assert byte_size(record.raw) == 4
    end

    test "raw matches tuple values" do
      record = A.new({10, 20, 30, 40})
      assert record.raw == <<10, 20, 30, 40>>
    end
  end

  describe "concurrency" do
    test "multiple A record creations are thread-safe" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            A.new({192, 168, 1, i})
          end)
        end

      results = Task.await_many(tasks)

      for {result, i} <- Enum.with_index(results, 1) do
        assert %A{} = result
        assert result.data == {192, 168, 1, i}
      end
    end
  end

  describe "comparison and equality" do
    test "two A records with same IP are equal in data" do
      record1 = A.new({192, 168, 1, 1})
      record2 = A.new({192, 168, 1, 1})
      assert record1.data == record2.data
    end

    test "two A records with different IPs differ in data" do
      record1 = A.new({192, 168, 1, 1})
      record2 = A.new({192, 168, 1, 2})
      refute record1.data == record2.data
    end
  end

  describe "integration with DNS message" do
    test "A record can be used in resource record" do
      a_record = A.new({192, 168, 1, 1})
      # Verify it has the fields needed for a resource record
      assert a_record.type != nil
      assert a_record.rdlength != nil
      assert a_record.data != nil
    end

    test "multiple A records for same domain" do
      # Load balancing scenario - multiple IPs for one domain
      ips = [
        {192, 168, 1, 1},
        {192, 168, 1, 2},
        {192, 168, 1, 3}
      ]

      records =
        for ip <- ips do
          A.new(ip)
        end

      for {record, ip} <- Enum.zip(records, ips) do
        assert %A{} = record
        assert record.data == ip
      end
    end
  end

  describe "class A/B/C networks" do
    test "creates record for Class A network (1.x.x.x - 126.x.x.x)" do
      record = A.new({10, 0, 0, 1})
      assert record.data == {10, 0, 0, 1}
    end

    test "creates record for Class B network (128.x.x.x - 191.x.x.x)" do
      record = A.new({172, 16, 0, 1})
      assert record.data == {172, 16, 0, 1}
    end

    test "creates record for Class C network (192.x.x.x - 223.x.x.x)" do
      record = A.new({192, 168, 1, 1})
      assert record.data == {192, 168, 1, 1}
    end
  end

  describe "performance" do
    test "creating many A records is efficient" do
      records =
        for i <- 1..100 do
          A.new({192, 168, rem(i, 256), rem(i + 1, 256)})
        end

      assert length(records) == 100

      for record <- records do
        assert %A{} = record
      end
    end
  end
end
