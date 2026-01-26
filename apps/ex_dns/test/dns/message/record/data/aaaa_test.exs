defmodule DNS.Message.Record.Data.AAAATest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.AAAA.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with IPv6 address tuples
  - from_iodata/1, from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 3596)
  - Edge cases and special IPv6 addresses
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.AAAA

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(AAAA)
    end

    test "exports new/1" do
      Code.ensure_loaded!(AAAA)
      assert Kernel.function_exported?(AAAA, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(AAAA)
      assert Kernel.function_exported?(AAAA, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(AAAA)
      assert Kernel.function_exported?(AAAA, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(AAAA)
      assert is_struct(AAAA.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %AAAA{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %AAAA{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %AAAA{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %AAAA{}
      assert Map.has_key?(record, :data)
    end

    test "default rdlength is 16" do
      assert %AAAA{}.rdlength == 16
    end

    test "default type is AAAA (28)" do
      type = %AAAA{}.type
      assert type == DNS.ResourceRecordType.new(28)
    end

    test "default raw is nil" do
      assert %AAAA{}.raw == nil
    end

    test "default data is nil" do
      assert %AAAA{}.data == nil
    end
  end

  describe "new/1" do
    test "creates AAAA record from IPv6 tuple" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2001:4860:4860::8888")
      record = AAAA.new(ip)
      assert %AAAA{} = record
      assert record.data == ip
    end

    test "stores raw binary" do
      ip = {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
      record = AAAA.new(ip)

      assert record.raw ==
               <<0x2001::16, 0x4860::16, 0x4860::16, 0::16, 0::16, 0::16, 0::16, 0x8888::16>>
    end

    test "creates record for Google DNS" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2001:4860:4860::8888")
      record = AAAA.new(ip)
      assert record.data == {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
    end

    test "creates record for Cloudflare DNS" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2606:4700:4700::1111")
      record = AAAA.new(ip)
      assert record.data == {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}
    end

    test "creates record for localhost" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "creates record for unspecified address" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 0})
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 0}
    end

    test "creates record for link-local address" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"fe80::1")
      record = AAAA.new(ip)
      assert record.data == {0xFE80, 0, 0, 0, 0, 0, 0, 1}
    end

    test "creates record with all segments non-zero" do
      ip = {0x2001, 0x0DB8, 0x85A3, 0x0000, 0x0000, 0x8A2E, 0x0370, 0x7334}
      record = AAAA.new(ip)
      assert record.data == ip
    end

    test "creates record with max values" do
      ip = {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      record = AAAA.new(ip)
      assert record.data == ip
    end
  end

  describe "from_iodata/1" do
    test "parses 16-byte binary" do
      raw = <<0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0x88>>
      record = AAAA.from_iodata(raw)
      assert %AAAA{} = record
      assert record.data == {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
    end

    test "stores raw binary" do
      raw = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = AAAA.from_iodata(raw)
      assert record.raw == raw
    end

    test "parses localhost" do
      raw = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = AAAA.from_iodata(raw)
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "parses unspecified address" do
      raw = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
      record = AAAA.from_iodata(raw)
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 0}
    end

    test "parses max address" do
      raw =
        <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
          0xFF, 0xFF>>

      record = AAAA.from_iodata(raw)
      assert record.data == {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
    end
  end

  describe "from_iodata/2" do
    test "accepts message parameter (ignored)" do
      raw = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = AAAA.from_iodata(raw, <<>>)
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "message can be nil" do
      raw = <<0x20, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = AAAA.from_iodata(raw, nil)
      assert record.data == {0x2001, 0, 0, 0, 0, 0, 0, 1}
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats IPv6 address correctly" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2001:4860:4860::8888")
      record = AAAA.new(ip)
      str = to_string(record)
      # Should be valid IPv6 format (may use compression)
      assert str =~ "2001:4860:4860"
      assert str =~ "8888"
    end

    test "formats localhost" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      str = to_string(record)
      # inet.ntoa returns "::1" for localhost
      assert str == "::1"
    end

    test "formats unspecified address" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 0})
      str = to_string(record)
      # inet.ntoa returns "::" for all zeros
      assert str == "::"
    end

    test "string interpolation works" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2001:db8::1")
      record = AAAA.new(ip)
      result = "IPv6: #{record}"
      assert result =~ "IPv6:"
      assert result =~ "2001"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      record = AAAA.new({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
      iodata = DNS.Parameter.to_iodata(record)
      # AAAA record wire format: 2-byte length (16) + 16-byte IP
      <<length::16, ip_bytes::binary>> = iodata
      assert length == 16
      assert byte_size(ip_bytes) == 16
    end

    test "wire format has 18 bytes total" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      iodata = DNS.Parameter.to_iodata(record)
      assert byte_size(iodata) == 18
    end

    test "length prefix is always 16" do
      record = AAAA.new({1, 2, 3, 4, 5, 6, 7, 8})
      <<length::16, _rest::binary>> = DNS.Parameter.to_iodata(record)
      assert length == 16
    end

    test "IP segments are in network byte order" do
      record = AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      <<16::16, a::16, b::16, _::binary>> = DNS.Parameter.to_iodata(record)
      assert a == 0x2001
      assert b == 0x0DB8
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      original_ip = {0x2001, 0x0DB8, 0x85A3, 0, 0, 0x8A2E, 0x0370, 0x7334}
      record = AAAA.new(original_ip)
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      parsed = AAAA.from_iodata(raw)
      assert parsed.data == original_ip
    end

    test "from_iodata -> to_string -> parseable" do
      raw = <<0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = AAAA.from_iodata(raw)
      str = to_string(record)
      {:ok, _parsed_ip} = :inet.parse_ipv6_address(String.to_charlist(str))
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2001:4860:4860::8888")
      record = AAAA.new(ip)
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "all segments at boundary values" do
      record = AAAA.new({0, 0x7FFF, 0xFFFF, 0, 0, 0, 0, 1})
      assert record.data == {0, 0x7FFF, 0xFFFF, 0, 0, 0, 0, 1}
    end

    test "rdlength is always 16" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"::1")
      record = AAAA.new(ip)
      assert record.rdlength == 16
    end

    test "IPv4-mapped IPv6 address" do
      # ::ffff:192.168.1.1 represented as IPv6
      ip = {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101}
      record = AAAA.new(ip)
      assert record.data == ip
    end
  end

  describe "RFC compliance" do
    test "AAAA record type value is 28 per RFC 3596" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      # RFC 3596 Section 2.1: AAAA = 28
      # type.value is binary <<0, 28>> representing 16-bit value
      assert record.type.value == <<0, 28>>
    end

    test "rdlength is 16 bytes per RFC 3596" do
      record = AAAA.new({0x2001, 0, 0, 0, 0, 0, 0, 1})
      # RFC 3596 Section 2.2: AAAA RDATA is 128-bit (16 byte) IPv6 address
      assert record.rdlength == 16
    end

    test "wire format uses network byte order (big-endian)" do
      record = AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      <<_length::16, s1::16, s2::16, _rest::binary>> = DNS.Parameter.to_iodata(record)
      # Segments are in order: first segment first
      assert s1 == 0x2001
      assert s2 == 0x0DB8
    end
  end

  describe "special IPv6 addresses" do
    test "creates record for loopback (::1)" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 1}
      assert to_string(record) == "::1"
    end

    test "creates record for unspecified address (::)" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 0})
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 0}
      assert to_string(record) == "::"
    end

    test "creates record for link-local range (fe80::/10)" do
      link_local_addrs = [
        {0xFE80, 0, 0, 0, 0, 0, 0, 1},
        {0xFE80, 0, 0, 0, 0x1234, 0x5678, 0x9ABC, 0xDEF0}
      ]

      for addr <- link_local_addrs do
        record = AAAA.new(addr)
        assert record.data == addr
      end
    end

    test "creates record for site-local range (deprecated fec0::/10)" do
      record = AAAA.new({0xFEC0, 0, 0, 0, 0, 0, 0, 1})
      assert record.data == {0xFEC0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "creates record for multicast range (ff00::/8)" do
      multicast_addrs = [
        # All nodes (link-local)
        {0xFF02, 0, 0, 0, 0, 0, 0, 1},
        # All routers (link-local)
        {0xFF02, 0, 0, 0, 0, 0, 0, 2},
        # mDNS
        {0xFF02, 0, 0, 0, 0, 0, 0, 0xFB}
      ]

      for addr <- multicast_addrs do
        record = AAAA.new(addr)
        assert record.data == addr
      end
    end

    test "creates record for unique local addresses (fc00::/7)" do
      record = AAAA.new({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert record.data == {0xFC00, 0, 0, 0, 0, 0, 0, 1}
    end

    test "creates record for documentation range (2001:db8::/32)" do
      # RFC 3849: 2001:db8::/32 for documentation
      record = AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      assert record.data == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
    end
  end

  describe "well-known DNS servers" do
    test "creates record for Cloudflare DNS servers" do
      cloudflare_dns = [
        {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111},
        {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1001}
      ]

      for addr <- cloudflare_dns do
        record = AAAA.new(addr)
        assert record.data == addr
      end
    end

    test "creates record for Google DNS servers" do
      google_dns = [
        {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888},
        {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8844}
      ]

      for addr <- google_dns do
        record = AAAA.new(addr)
        assert record.data == addr
      end
    end

    test "creates record for Quad9 DNS servers" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2620:fe::fe")
      record = AAAA.new(ip)
      assert record.data == ip
    end
  end

  describe "IPv4/IPv6 transition addresses" do
    test "creates record for IPv4-mapped IPv6 (::ffff:a.b.c.d)" do
      # ::ffff:192.168.1.1
      ip = {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101}
      record = AAAA.new(ip)
      assert record.data == ip
    end

    test "creates record for 6to4 address (2002::/16)" do
      # 6to4 prefix encodes IPv4 address
      record = AAAA.new({0x2002, 0xC0A8, 0x0101, 0, 0, 0, 0, 1})
      assert record.data == {0x2002, 0xC0A8, 0x0101, 0, 0, 0, 0, 1}
    end

    test "creates record for Teredo address (2001:0::/32)" do
      # Teredo tunneling prefix
      record = AAAA.new({0x2001, 0, 0, 0, 0, 0, 0, 1})
      assert record.data == {0x2001, 0, 0, 0, 0, 0, 0, 1}
    end
  end

  describe "type field" do
    test "type field is DNS.ResourceRecordType struct" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      assert %DNS.ResourceRecordType{} = record.type
    end

    test "type can be compared with new type" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      aaaa_type = DNS.ResourceRecordType.new(:aaaa)
      assert record.type == aaaa_type
    end

    test "type can be compared by value" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      # Value is 16-bit binary representation (28 = 0x1C)
      assert record.type.value == <<0, 28>>
    end
  end

  describe "data field" do
    test "data is 8-tuple of integers" do
      record = AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      assert is_tuple(record.data)
      assert tuple_size(record.data) == 8
    end

    test "data tuple values are 0-65535" do
      record = AAAA.new({0x2001, 0x0DB8, 0xFFFF, 0, 0, 0, 0, 1})

      for segment <- Tuple.to_list(record.data) do
        assert segment >= 0 and segment <= 65535
      end
    end
  end

  describe "raw field" do
    test "raw field is 16-byte binary" do
      record = AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      assert is_binary(record.raw)
      assert byte_size(record.raw) == 16
    end

    test "raw matches tuple values" do
      record = AAAA.new({0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007, 0x0008})
      expected_raw = <<1::16, 2::16, 3::16, 4::16, 5::16, 6::16, 7::16, 8::16>>
      assert record.raw == expected_raw
    end
  end

  describe "concurrency" do
    test "multiple AAAA record creations are thread-safe" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, i})
          end)
        end

      results = Task.await_many(tasks)

      for {result, i} <- Enum.with_index(results, 1) do
        assert %AAAA{} = result
        assert result.data == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, i}
      end
    end
  end

  describe "comparison and equality" do
    test "two AAAA records with same IP are equal in data" do
      record1 = AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      record2 = AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      assert record1.data == record2.data
    end

    test "two AAAA records with different IPs differ in data" do
      record1 = AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      record2 = AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 2})
      refute record1.data == record2.data
    end
  end

  describe "integration with DNS message" do
    test "AAAA record can be used in resource record" do
      aaaa_record = AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      # Verify it has the fields needed for a resource record
      assert aaaa_record.type != nil
      assert aaaa_record.rdlength != nil
      assert aaaa_record.data != nil
    end

    test "multiple AAAA records for same domain" do
      # Load balancing scenario - multiple IPv6 addresses for one domain
      ips = [
        {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
        {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 2},
        {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 3}
      ]

      records =
        for ip <- ips do
          AAAA.new(ip)
        end

      for {record, ip} <- Enum.zip(records, ips) do
        assert %AAAA{} = record
        assert record.data == ip
      end
    end
  end

  describe "global unicast addresses" do
    test "creates record for global unicast (2000::/3)" do
      global_addrs = [
        {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
        # Example Google
        {0x2607, 0xF8B0, 0x4004, 0x800, 0, 0, 0, 0x200E}
      ]

      for addr <- global_addrs do
        record = AAAA.new(addr)
        assert record.data == addr
      end
    end
  end

  describe "performance" do
    test "creating many AAAA records is efficient" do
      records =
        for i <- 1..100 do
          AAAA.new({0x2001, 0x0DB8, 0, 0, 0, 0, 0, i})
        end

      assert length(records) == 100

      for record <- records do
        assert %AAAA{} = record
      end
    end
  end
end
