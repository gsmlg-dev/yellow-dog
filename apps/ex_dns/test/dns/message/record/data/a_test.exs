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
end
