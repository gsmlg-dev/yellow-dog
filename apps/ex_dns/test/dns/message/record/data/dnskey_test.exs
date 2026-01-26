defmodule DNS.Message.Record.Data.DNSKEYTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.DNSKEY.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with 4-element tuple
  - from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 4034)
  - DNSSEC key semantics (flags, protocol, algorithm)
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias DNS.Message.Record.Data.DNSKEY

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(DNSKEY)
    end

    test "exports new/1" do
      Code.ensure_loaded!(DNSKEY)
      assert Kernel.function_exported?(DNSKEY, :new, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(DNSKEY)
      assert Kernel.function_exported?(DNSKEY, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(DNSKEY)
      assert is_struct(DNSKEY.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %DNSKEY{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %DNSKEY{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %DNSKEY{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %DNSKEY{}
      assert Map.has_key?(record, :data)
    end

    test "default type is DNSKEY (48)" do
      type = %DNSKEY{}.type
      assert type == DNS.ResourceRecordType.new(48)
    end

    test "default raw is nil" do
      assert %DNSKEY{}.raw == nil
    end

    test "default data is nil" do
      assert %DNSKEY{}.data == nil
    end
  end

  describe "new/1" do
    test "creates DNSKEY record from 4-element tuple" do
      flags = 257
      protocol = 3
      algorithm = 8
      public_key = :binary.copy(<<0x01>>, 64)

      record = DNSKEY.new({flags, protocol, algorithm, public_key})
      assert %DNSKEY{} = record
      assert record.data == {flags, protocol, algorithm, public_key}
    end

    test "stores flags" do
      record = DNSKEY.new({256, 3, 8, <<1, 2, 3>>})
      {flags, _, _, _} = record.data
      assert flags == 256
    end

    test "stores protocol" do
      record = DNSKEY.new({256, 3, 8, <<1, 2, 3>>})
      {_, protocol, _, _} = record.data
      assert protocol == 3
    end

    test "stores algorithm" do
      record = DNSKEY.new({256, 3, 13, <<1, 2, 3>>})
      {_, _, algorithm, _} = record.data
      assert algorithm == 13
    end

    test "stores public key" do
      public_key = :binary.copy(<<0xAB>>, 128)
      record = DNSKEY.new({256, 3, 8, public_key})
      {_, _, _, pk} = record.data
      assert pk == public_key
    end

    test "raw field contains binary data" do
      record = DNSKEY.new({256, 3, 8, <<1, 2, 3>>})
      assert is_binary(record.raw)
    end

    test "rdlength is 4 + public key size" do
      public_key = :binary.copy(<<0x01>>, 64)
      record = DNSKEY.new({256, 3, 8, public_key})
      assert record.rdlength == 4 + 64
    end

    test "raw format is correct" do
      flags = 257
      protocol = 3
      algorithm = 8
      public_key = <<1, 2, 3, 4>>

      record = DNSKEY.new({flags, protocol, algorithm, public_key})
      expected_raw = <<flags::16, protocol::8, algorithm::8, public_key::binary>>
      assert record.raw == expected_raw
    end

    test "creates Zone Key (flag bit 7)" do
      # 256 = Zone Key flag set
      record = DNSKEY.new({256, 3, 8, <<1, 2, 3>>})
      {flags, _, _, _} = record.data
      assert flags == 256
    end

    test "creates Zone Key with SEP (flag bits 7 and 0)" do
      # 257 = Zone Key + Secure Entry Point
      record = DNSKEY.new({257, 3, 8, <<1, 2, 3>>})
      {flags, _, _, _} = record.data
      assert flags == 257
    end

    test "creates DNSKEY with Revoke flag" do
      # 128 = Revoke flag
      record = DNSKEY.new({128, 3, 8, <<1, 2, 3>>})
      {flags, _, _, _} = record.data
      assert flags == 128
    end

    test "handles minimal DNSKEY record" do
      record = DNSKEY.new({0, 0, 0, <<>>})
      assert %DNSKEY{} = record
      assert record.rdlength == 4
    end
  end

  describe "from_iodata/2" do
    test "parses DNSKEY from binary" do
      flags = 257
      protocol = 3
      algorithm = 8
      public_key = :binary.copy(<<0x01>>, 64)
      raw = <<flags::16, protocol::8, algorithm::8, public_key::binary>>

      record = DNSKEY.from_iodata(raw)
      assert %DNSKEY{} = record
    end

    test "parses flags correctly" do
      raw = <<257::16, 3::8, 8::8, 1, 2, 3>>
      record = DNSKEY.from_iodata(raw)
      {flags, _, _, _} = record.data
      assert flags == 257
    end

    test "parses protocol correctly" do
      raw = <<256::16, 3::8, 8::8, 1, 2, 3>>
      record = DNSKEY.from_iodata(raw)
      {_, protocol, _, _} = record.data
      assert protocol == 3
    end

    test "parses algorithm correctly" do
      raw = <<256::16, 3::8, 13::8, 1, 2, 3>>
      record = DNSKEY.from_iodata(raw)
      {_, _, algorithm, _} = record.data
      assert algorithm == 13
    end

    test "parses public key correctly" do
      public_key = <<0xAB, 0xCD, 0xEF, 0x12>>
      raw = <<256::16, 3::8, 8::8, public_key::binary>>
      record = DNSKEY.from_iodata(raw)
      {_, _, _, pk} = record.data
      assert pk == public_key
    end

    test "stores raw binary" do
      raw = <<257::16, 3::8, 8::8, 1, 2, 3>>
      record = DNSKEY.from_iodata(raw)
      assert record.raw == raw
    end

    test "sets rdlength from raw size" do
      raw = <<256::16, 3::8, 8::8, 1, 2, 3>>
      record = DNSKEY.from_iodata(raw)
      assert record.rdlength == byte_size(raw)
    end

    test "message parameter can be nil" do
      raw = <<256::16, 3::8, 8::8, 1, 2, 3>>
      record = DNSKEY.from_iodata(raw, nil)
      assert %DNSKEY{} = record
    end

    test "parses short DNSKEY record" do
      raw = <<256::16, 3::8, 5::8, 0xAA, 0xBB, 0xCC>>
      record = DNSKEY.from_iodata(raw)
      assert record.rdlength == 7
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'flags protocol algorithm public_key_b64'" do
      public_key = <<1, 2, 3, 4>>
      record = DNSKEY.new({257, 3, 8, public_key})
      str = to_string(record)
      public_key_b64 = Base.encode64(public_key)
      assert str == "257 3 8 #{public_key_b64}"
    end

    test "public key is base64 encoded" do
      public_key = <<0xAB, 0xCD, 0xEF>>
      record = DNSKEY.new({256, 3, 8, public_key})
      str = to_string(record)
      assert str =~ Base.encode64(public_key)
    end

    test "string interpolation works" do
      record = DNSKEY.new({257, 3, 8, <<1, 2, 3>>})
      result = "DNSKEY: #{record}"
      assert result =~ "DNSKEY:"
      assert result =~ "257"
    end

    test "formats minimal DNSKEY record" do
      record = DNSKEY.new({0, 0, 0, <<>>})
      str = to_string(record)
      assert str == "0 0 0 "
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      public_key = :binary.copy(<<0x01>>, 64)
      record = DNSKEY.new({257, 3, 8, public_key})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length == 4 + 64
    end

    test "length prefix matches content" do
      public_key = <<1, 2, 3, 4>>
      record = DNSKEY.new({256, 3, 8, public_key})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, rest::binary>> = iodata
      assert length == byte_size(rest)
    end

    test "wire format has correct structure" do
      flags = 257
      protocol = 3
      algorithm = 8
      public_key = <<1, 2, 3, 4>>

      record = DNSKEY.new({flags, protocol, algorithm, public_key})
      iodata = DNS.Parameter.to_iodata(record)

      expected_size = 4 + byte_size(public_key)
      expected = <<expected_size::16, flags::16, protocol::8, algorithm::8, public_key::binary>>
      assert iodata == expected
    end

    test "converts minimal DNSKEY to iodata" do
      record = DNSKEY.new({0, 0, 0, <<>>})
      iodata = DNS.Parameter.to_iodata(record)
      expected = <<4::16, 0::16, 0::8, 0::8>>
      assert iodata == expected
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back preserves data" do
      flags = 257
      protocol = 3
      algorithm = 8
      public_key = :binary.copy(<<0xAB>>, 64)

      original = DNSKEY.new({flags, protocol, algorithm, public_key})
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = DNSKEY.from_iodata(raw)

      assert parsed.data == {flags, protocol, algorithm, public_key}
    end

    test "round-trip preserves different configurations" do
      test_cases = [
        {256, 3, 8, <<1, 2, 3>>},
        {257, 3, 13, :binary.copy(<<0xCD>>, 64)},
        {128, 3, 15, :binary.copy(<<0xEF>>, 32)}
      ]

      for {f, p, a, pk} <- test_cases do
        original = DNSKEY.new({f, p, a, pk})
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
        parsed = DNSKEY.from_iodata(raw)
        assert parsed.data == {f, p, a, pk}
      end
    end
  end

  describe "DNSSEC key semantics" do
    test "Zone Key flag (bit 7) = 256" do
      record = DNSKEY.new({256, 3, 8, <<1, 2, 3>>})
      {flags, _, _, _} = record.data
      assert (flags &&& 256) == 256
    end

    test "SEP flag (bit 0) = 1" do
      record = DNSKEY.new({257, 3, 8, <<1, 2, 3>>})
      {flags, _, _, _} = record.data
      assert (flags &&& 1) == 1
    end

    test "Revoke flag (bit 8) = 128" do
      record = DNSKEY.new({128, 3, 8, <<1, 2, 3>>})
      {flags, _, _, _} = record.data
      assert flags == 128
    end

    test "protocol must be 3 for DNSSEC" do
      record = DNSKEY.new({256, 3, 8, <<1, 2, 3>>})
      {_, protocol, _, _} = record.data
      assert protocol == 3
    end

    test "algorithm 8 is RSA/SHA-256" do
      record = DNSKEY.new({256, 3, 8, <<1, 2, 3>>})
      {_, _, algorithm, _} = record.data
      assert algorithm == 8
    end

    test "algorithm 13 is ECDSA P-256" do
      record = DNSKEY.new({256, 3, 13, <<1, 2, 3>>})
      {_, _, algorithm, _} = record.data
      assert algorithm == 13
    end

    test "algorithm 14 is ECDSA P-384" do
      record = DNSKEY.new({256, 3, 14, <<1, 2, 3>>})
      {_, _, algorithm, _} = record.data
      assert algorithm == 14
    end

    test "algorithm 15 is Ed25519" do
      record = DNSKEY.new({256, 3, 15, <<1, 2, 3>>})
      {_, _, algorithm, _} = record.data
      assert algorithm == 15
    end

    test "algorithm 16 is Ed448" do
      record = DNSKEY.new({256, 3, 16, <<1, 2, 3>>})
      {_, _, algorithm, _} = record.data
      assert algorithm == 16
    end

    test "KSK has both Zone Key and SEP flags" do
      # KSK (Key Signing Key) = 257 = 256 + 1
      record = DNSKEY.new({257, 3, 8, <<1, 2, 3>>})
      {flags, _, _, _} = record.data
      assert (flags &&& 256) == 256
      assert (flags &&& 1) == 1
    end

    test "ZSK has only Zone Key flag" do
      # ZSK (Zone Signing Key) = 256
      record = DNSKEY.new({256, 3, 8, <<1, 2, 3>>})
      {flags, _, _, _} = record.data
      assert (flags &&& 256) == 256
      assert (flags &&& 1) == 0
    end
  end

  describe "common key configurations" do
    test "RSA 2048-bit key" do
      # RSA 2048-bit public key is ~270 bytes
      public_key = :binary.copy(<<0x01>>, 270)
      record = DNSKEY.new({257, 3, 8, public_key})
      assert record.rdlength == 4 + 270
    end

    test "ECDSA P-256 key" do
      # ECDSA P-256 public key is 64 bytes (x + y coordinates)
      public_key = :binary.copy(<<0x02>>, 64)
      record = DNSKEY.new({257, 3, 13, public_key})
      assert record.rdlength == 4 + 64
    end

    test "Ed25519 key" do
      # Ed25519 public key is 32 bytes
      public_key = :binary.copy(<<0x03>>, 32)
      record = DNSKEY.new({257, 3, 15, public_key})
      assert record.rdlength == 4 + 32
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = DNSKEY.new({257, 3, 8, <<1, 2, 3>>})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "maximum flags value" do
      record = DNSKEY.new({65535, 3, 8, <<1, 2, 3>>})
      {flags, _, _, _} = record.data
      assert flags == 65535
    end

    test "maximum protocol value" do
      record = DNSKEY.new({256, 255, 8, <<1, 2, 3>>})
      {_, protocol, _, _} = record.data
      assert protocol == 255
    end

    test "maximum algorithm value" do
      record = DNSKEY.new({256, 3, 255, <<1, 2, 3>>})
      {_, _, algorithm, _} = record.data
      assert algorithm == 255
    end

    test "empty public key" do
      record = DNSKEY.new({256, 3, 8, <<>>})
      {_, _, _, pk} = record.data
      assert pk == <<>>
    end

    test "large public key" do
      public_key = :binary.copy(<<0xFF>>, 512)
      record = DNSKEY.new({256, 3, 8, public_key})
      {_, _, _, pk} = record.data
      assert byte_size(pk) == 512
    end

    test "all zeros" do
      record = DNSKEY.new({0, 0, 0, <<>>})
      {f, p, a, pk} = record.data
      assert {f, p, a, pk} == {0, 0, 0, <<>>}
    end
  end
end
