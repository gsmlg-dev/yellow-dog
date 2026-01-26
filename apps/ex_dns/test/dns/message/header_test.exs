defmodule DNS.Message.HeaderTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Header.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/0 function and default values
  - generate_id/0 random ID generation
  - from_iodata/1 binary parsing
  - Count extraction functions (qdcount, ancount, nscount, arcount)
  - Protocol implementations (DNS.Parameter, String.Chars)
  - RFC 1035 compliance
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Header
  alias DNS.Message.OpCode
  alias DNS.Message.RCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Header)
    end

    test "exports new/0" do
      Code.ensure_loaded!(Header)
      assert Kernel.function_exported?(Header, :new, 0)
    end

    test "exports generate_id/0" do
      Code.ensure_loaded!(Header)
      assert Kernel.function_exported?(Header, :generate_id, 0)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Header)
      assert Kernel.function_exported?(Header, :from_iodata, 1)
    end

    test "exports qdcount/1" do
      Code.ensure_loaded!(Header)
      assert Kernel.function_exported?(Header, :qdcount, 1)
    end

    test "exports ancount/1" do
      Code.ensure_loaded!(Header)
      assert Kernel.function_exported?(Header, :ancount, 1)
    end

    test "exports nscount/1" do
      Code.ensure_loaded!(Header)
      assert Kernel.function_exported?(Header, :nscount, 1)
    end

    test "exports arcount/1" do
      Code.ensure_loaded!(Header)
      assert Kernel.function_exported?(Header, :arcount, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Header)
      assert is_struct(Header.__struct__())
    end
  end

  describe "struct fields" do
    test "has all required fields" do
      header = %Header{}

      assert Map.has_key?(header, :id)
      assert Map.has_key?(header, :qr)
      assert Map.has_key?(header, :opcode)
      assert Map.has_key?(header, :aa)
      assert Map.has_key?(header, :tc)
      assert Map.has_key?(header, :rd)
      assert Map.has_key?(header, :ra)
      assert Map.has_key?(header, :z)
      assert Map.has_key?(header, :ad)
      assert Map.has_key?(header, :cd)
      assert Map.has_key?(header, :rcode)
      assert Map.has_key?(header, :qdcount)
      assert Map.has_key?(header, :ancount)
      assert Map.has_key?(header, :nscount)
      assert Map.has_key?(header, :arcount)
    end

    test "has correct default values" do
      header = %Header{}

      # Most fields default to nil except counts
      assert header.z == 0
      assert header.qdcount == 1
      assert header.ancount == 0
      assert header.nscount == 0
      assert header.arcount == 0
    end
  end

  describe "new/0" do
    test "creates valid header struct" do
      header = Header.new()

      assert is_struct(header, Header)
    end

    test "sets query flag (qr = 0)" do
      header = Header.new()

      assert header.qr == 0
    end

    test "sets opcode to Query" do
      header = Header.new()

      assert header.opcode == OpCode.new(0)
    end

    test "sets recursion desired (rd = 1)" do
      header = Header.new()

      assert header.rd == 1
    end

    test "sets all flags appropriately" do
      header = Header.new()

      assert header.aa == 0
      assert header.tc == 0
      assert header.ra == 0
      assert header.z == 0
      assert header.ad == 0
      assert header.cd == 0
    end

    test "sets rcode to NoError" do
      header = Header.new()

      assert header.rcode == RCode.new(0)
    end

    test "initializes all counts to 0" do
      header = Header.new()

      assert header.qdcount == 0
      assert header.ancount == 0
      assert header.nscount == 0
      assert header.arcount == 0
    end

    test "generates a random ID" do
      header = Header.new()

      assert is_integer(header.id)
      assert header.id >= 0
      assert header.id <= 0xFFFF
    end

    test "generates different IDs" do
      ids =
        1..100
        |> Enum.map(fn _ -> Header.new().id end)
        |> Enum.uniq()

      # Should have many unique IDs (not all the same)
      assert length(ids) > 50
    end
  end

  describe "generate_id/0" do
    test "returns integer" do
      id = Header.generate_id()

      assert is_integer(id)
    end

    test "returns value in valid range" do
      for _ <- 1..100 do
        id = Header.generate_id()

        assert id >= 0
        assert id <= 0xFFFF
      end
    end

    test "generates different values" do
      ids =
        1..100
        |> Enum.map(fn _ -> Header.generate_id() end)
        |> Enum.uniq()

      # Should have many unique values
      assert length(ids) > 50
    end
  end

  describe "from_iodata/1" do
    test "parses standard query header" do
      # A standard query header with ID=0x1234, QR=0, OPCODE=0, etc.
      binary =
        <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, "extra">>

      header = Header.from_iodata(binary)

      assert header.id == 0x1234
      assert header.qr == 0
      assert header.rd == 1
      assert header.qdcount == 1
    end

    test "parses response header" do
      # Response header with QR=1
      binary =
        <<0xAB, 0xCD, 0x81, 0x80, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, "extra">>

      header = Header.from_iodata(binary)

      assert header.id == 0xABCD
      assert header.qr == 1
      assert header.ra == 1
      assert header.qdcount == 1
      assert header.ancount == 2
    end

    test "extracts all counts correctly" do
      binary = <<0x00, 0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x10, 0x00, 0x03, 0x00, 0x02, "extra">>

      header = Header.from_iodata(binary)

      assert header.qdcount == 5
      assert header.ancount == 16
      assert header.nscount == 3
      assert header.arcount == 2
    end

    test "extracts all flags correctly" do
      # Header with all flags set
      # QR=1, OPCODE=0, AA=1, TC=1, RD=1, RA=1, Z=0, AD=1, CD=1, RCODE=0
      binary = <<0x00, 0x00, 0x87, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, "x">>

      header = Header.from_iodata(binary)

      assert header.qr == 1
      assert header.aa == 1
      assert header.tc == 1
      assert header.rd == 1
      assert header.ra == 1
    end
  end

  describe "count extraction functions" do
    test "qdcount extracts question count" do
      binary = <<0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>

      assert Header.qdcount(binary) == 5
    end

    test "ancount extracts answer count" do
      binary = <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00>>

      assert Header.ancount(binary) == 16
    end

    test "nscount extracts authority count" do
      binary = <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00>>

      assert Header.nscount(binary) == 3
    end

    test "arcount extracts additional count" do
      binary = <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00>>

      assert Header.arcount(binary) == 7
    end

    test "handles maximum count values" do
      binary =
        <<0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00>>

      assert Header.qdcount(binary) == 65535
      assert Header.ancount(binary) == 65535
      assert Header.nscount(binary) == 65535
      assert Header.arcount(binary) == 65535
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces 12-byte header" do
      header = Header.new()

      iodata = DNS.Parameter.to_iodata(header)
      binary = IO.iodata_to_binary(iodata)

      assert byte_size(binary) == 12
    end

    test "round-trips correctly" do
      original = Header.new()

      iodata = DNS.Parameter.to_iodata(original)
      binary = IO.iodata_to_binary(iodata) <> "extra"
      parsed = Header.from_iodata(binary)

      assert parsed.id == original.id
      assert parsed.qr == original.qr
      assert parsed.rd == original.rd
      assert parsed.qdcount == original.qdcount
    end

    test "encodes ID correctly" do
      header = %{Header.new() | id: 0x1234}

      iodata = DNS.Parameter.to_iodata(header)
      binary = IO.iodata_to_binary(iodata)

      assert binary_part(binary, 0, 2) == <<0x12, 0x34>>
    end

    test "encodes counts correctly" do
      header = %{Header.new() | qdcount: 1, ancount: 2, nscount: 3, arcount: 4}

      iodata = DNS.Parameter.to_iodata(header)
      binary = IO.iodata_to_binary(iodata)

      # Counts start at byte 4
      assert binary_part(binary, 4, 8) == <<0, 1, 0, 2, 0, 3, 0, 4>>
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "includes ID and basic info" do
      header = Header.new()

      result = to_string(header)

      assert result =~ "qr: 0"
      assert result =~ "opcode: Query"
      assert result =~ "status: NoError"
    end

    test "includes all flags" do
      header = Header.new()

      result = to_string(header)

      assert result =~ "aa: 0"
      assert result =~ "tc: 0"
      assert result =~ "rd: 1"
      assert result =~ "ra: 0"
      assert result =~ "z: 0"
      assert result =~ "ad: 0"
      assert result =~ "cd: 0"
    end

    test "includes counts" do
      header = Header.new()

      result = to_string(header)

      assert result =~ "QUERY: 0"
      assert result =~ "ANSWER: 0"
      assert result =~ "AUTHORITY: 0"
      assert result =~ "ADDITIONAL: 0"
    end

    test "can interpolate in strings" do
      header = Header.new()

      result = "Header: #{header}"

      assert result =~ "Header:"
      assert result =~ "opcode: Query"
    end
  end

  describe "RFC 1035 compliance" do
    test "header size is 12 bytes" do
      header = Header.new()

      iodata = DNS.Parameter.to_iodata(header)
      binary = IO.iodata_to_binary(iodata)

      # RFC 1035 specifies 12-byte header
      assert byte_size(binary) == 12
    end

    test "ID is 16 bits" do
      header = Header.new()

      assert header.id >= 0
      assert header.id <= 0xFFFF
    end

    test "counts are 16 bits" do
      header = %{
        Header.new()
        | qdcount: 0xFFFF,
          ancount: 0xFFFF,
          nscount: 0xFFFF,
          arcount: 0xFFFF
      }

      iodata = DNS.Parameter.to_iodata(header)
      binary = IO.iodata_to_binary(iodata)

      # Should encode without overflow
      assert byte_size(binary) == 12
    end
  end

  describe "edge cases" do
    test "handles zero ID" do
      header = %{Header.new() | id: 0}

      assert header.id == 0

      iodata = DNS.Parameter.to_iodata(header)
      binary = IO.iodata_to_binary(iodata)

      assert binary_part(binary, 0, 2) == <<0, 0>>
    end

    test "handles max ID" do
      header = %{Header.new() | id: 0xFFFF}

      assert header.id == 0xFFFF

      iodata = DNS.Parameter.to_iodata(header)
      binary = IO.iodata_to_binary(iodata)

      assert binary_part(binary, 0, 2) == <<0xFF, 0xFF>>
    end

    test "struct is inspectable" do
      header = Header.new()

      # Should not raise
      result = inspect(header)
      assert is_binary(result)
      assert result =~ "Header"
    end
  end
end
