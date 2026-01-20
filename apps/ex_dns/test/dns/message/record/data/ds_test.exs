defmodule DNS.Message.Record.Data.DSTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.DS.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with 4-element tuple
  - from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 4034)
  - DNSSEC delegation signer semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.DS

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(DS)
    end

    test "exports new/1" do
      Code.ensure_loaded!(DS)
      assert Kernel.function_exported?(DS, :new, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(DS)
      assert Kernel.function_exported?(DS, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(DS)
      assert is_struct(DS.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %DS{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %DS{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %DS{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %DS{}
      assert Map.has_key?(record, :data)
    end

    test "default type is DS (43)" do
      type = %DS{}.type
      assert type == DNS.ResourceRecordType.new(43)
    end

    test "default raw is nil" do
      assert %DS{}.raw == nil
    end

    test "default data is nil" do
      assert %DS{}.data == nil
    end
  end

  describe "new/1" do
    test "creates DS record from 4-element tuple" do
      key_tag = 12345
      algorithm = 8
      digest_type = 2
      digest = :binary.copy(<<1>>, 32)

      record = DS.new({key_tag, algorithm, digest_type, digest})
      assert %DS{} = record
      assert record.data == {key_tag, algorithm, digest_type, digest}
    end

    test "stores key tag" do
      record = DS.new({54321, 8, 2, <<1, 2, 3>>})
      {key_tag, _, _, _} = record.data
      assert key_tag == 54321
    end

    test "stores algorithm" do
      record = DS.new({12345, 13, 2, <<1, 2, 3>>})
      {_, algorithm, _, _} = record.data
      assert algorithm == 13
    end

    test "stores digest type" do
      record = DS.new({12345, 8, 4, <<1, 2, 3>>})
      {_, _, digest_type, _} = record.data
      assert digest_type == 4
    end

    test "stores digest bytes" do
      digest = :binary.copy(<<0xAB>>, 32)
      record = DS.new({12345, 8, 2, digest})
      {_, _, _, d} = record.data
      assert d == digest
    end

    test "raw field contains binary data" do
      record = DS.new({12345, 8, 2, <<1, 2, 3>>})
      assert is_binary(record.raw)
    end

    test "rdlength is 4 + digest size" do
      digest = :binary.copy(<<1>>, 32)
      record = DS.new({12345, 8, 2, digest})
      # 2 (key_tag) + 1 (algorithm) + 1 (digest_type) + 32 (digest) = 36
      assert record.rdlength == 36
    end

    test "creates record with SHA-1 digest (20 bytes)" do
      digest = :binary.copy(<<1>>, 20)
      record = DS.new({12345, 8, 1, digest})
      # 2 + 1 + 1 + 20 = 24
      assert record.rdlength == 24
    end

    test "creates record with SHA-256 digest (32 bytes)" do
      digest = :binary.copy(<<1>>, 32)
      record = DS.new({12345, 8, 2, digest})
      # 2 + 1 + 1 + 32 = 36
      assert record.rdlength == 36
    end

    test "creates record with SHA-384 digest (48 bytes)" do
      digest = :binary.copy(<<1>>, 48)
      record = DS.new({12345, 8, 4, digest})
      # 2 + 1 + 1 + 48 = 52
      assert record.rdlength == 52
    end

    test "raw format is correct" do
      key_tag = 12345
      algorithm = 8
      digest_type = 2
      digest = <<1, 2, 3, 4>>

      record = DS.new({key_tag, algorithm, digest_type, digest})
      expected_raw = <<key_tag::16, algorithm::8, digest_type::8, digest::binary>>
      assert record.raw == expected_raw
    end

    test "handles minimal digest" do
      record = DS.new({1, 1, 0, <<>>})
      # 2 + 1 + 1 + 0 = 4
      assert record.rdlength == 4
    end
  end

  describe "from_iodata/2" do
    test "parses DS from binary" do
      key_tag = 12345
      algorithm = 8
      digest_type = 2
      digest = :binary.copy(<<1>>, 32)

      raw = <<key_tag::16, algorithm::8, digest_type::8, digest::binary>>
      record = DS.from_iodata(raw)
      assert %DS{} = record
    end

    test "parses key tag correctly" do
      raw = <<54321::16, 8::8, 2::8, 1, 2, 3>>
      record = DS.from_iodata(raw)
      {key_tag, _, _, _} = record.data
      assert key_tag == 54321
    end

    test "parses algorithm correctly" do
      raw = <<12345::16, 13::8, 2::8, 1, 2, 3>>
      record = DS.from_iodata(raw)
      {_, algorithm, _, _} = record.data
      assert algorithm == 13
    end

    test "parses digest type correctly" do
      raw = <<12345::16, 8::8, 4::8, 1, 2, 3>>
      record = DS.from_iodata(raw)
      {_, _, digest_type, _} = record.data
      assert digest_type == 4
    end

    test "parses digest correctly" do
      digest = <<1, 2, 3, 4, 5, 6, 7, 8>>
      raw = <<12345::16, 8::8, 2::8, digest::binary>>
      record = DS.from_iodata(raw)
      {_, _, _, d} = record.data
      assert d == digest
    end

    test "stores raw binary" do
      raw = <<12345::16, 8::8, 2::8, 1, 2, 3>>
      record = DS.from_iodata(raw)
      assert record.raw == raw
    end

    test "sets rdlength from raw size" do
      raw = <<12345::16, 8::8, 2::8, 1, 2, 3>>
      record = DS.from_iodata(raw)
      assert record.rdlength == byte_size(raw)
    end

    test "message parameter can be nil" do
      raw = <<12345::16, 8::8, 2::8, 1, 2, 3>>
      record = DS.from_iodata(raw, nil)
      assert %DS{} = record
    end

    test "message parameter can be empty binary" do
      raw = <<12345::16, 8::8, 2::8, 1, 2, 3>>
      record = DS.from_iodata(raw, <<>>)
      assert %DS{} = record
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'key_tag algorithm digest_type digest_hex'" do
      digest = <<1, 2, 3, 4, 5, 6, 7, 8>>
      record = DS.new({12345, 8, 2, digest})
      str = to_string(record)
      digest_hex = Base.encode16(digest, case: :lower)
      assert str == "12345 8 2 #{digest_hex}"
    end

    test "digest is lowercase hex encoded" do
      digest = <<0xAB, 0xCD, 0xEF>>
      record = DS.new({1, 1, 1, digest})
      str = to_string(record)
      assert str =~ "abcdef"
    end

    test "string interpolation works" do
      record = DS.new({12345, 8, 2, <<1, 2, 3>>})
      result = "DS: #{record}"
      assert result =~ "DS:"
      assert result =~ "12345"
    end

    test "formats SHA-1 digest" do
      digest = :binary.copy(<<0x11>>, 20)
      record = DS.new({12345, 8, 1, digest})
      str = to_string(record)
      assert str =~ "12345 8 1"
    end

    test "formats SHA-256 digest" do
      digest = :binary.copy(<<0x22>>, 32)
      record = DS.new({12345, 8, 2, digest})
      str = to_string(record)
      assert str =~ "12345 8 2"
    end

    test "formats SHA-384 digest" do
      digest = :binary.copy(<<0x33>>, 48)
      record = DS.new({12345, 8, 4, digest})
      str = to_string(record)
      assert str =~ "12345 8 4"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      digest = :binary.copy(<<1>>, 32)
      record = DS.new({12345, 8, 2, digest})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length == 36
    end

    test "length prefix matches content" do
      digest = <<1, 2, 3, 4>>
      record = DS.new({12345, 8, 2, digest})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, rest::binary>> = iodata
      assert length == byte_size(rest)
    end

    test "wire format has correct structure" do
      key_tag = 12345
      algorithm = 8
      digest_type = 2
      digest = <<1, 2, 3, 4>>

      record = DS.new({key_tag, algorithm, digest_type, digest})
      iodata = DNS.Parameter.to_iodata(record)

      expected_size = 4 + byte_size(digest)
      expected = <<expected_size::16, key_tag::16, algorithm::8, digest_type::8, digest::binary>>
      assert iodata == expected
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back preserves data" do
      key_tag = 12345
      algorithm = 8
      digest_type = 2
      digest = :binary.copy(<<0xAB>>, 32)

      original = DS.new({key_tag, algorithm, digest_type, digest})
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = DS.from_iodata(raw)

      assert parsed.data == {key_tag, algorithm, digest_type, digest}
    end

    test "round-trip preserves different digest sizes" do
      test_cases = [
        {12345, 8, 1, :binary.copy(<<1>>, 20)},
        {54321, 13, 2, :binary.copy(<<2>>, 32)},
        {11111, 8, 4, :binary.copy(<<3>>, 48)}
      ]

      for {kt, alg, dt, dig} <- test_cases do
        original = DS.new({kt, alg, dt, dig})
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
        parsed = DS.from_iodata(raw)
        assert parsed.data == {kt, alg, dt, dig}
      end
    end
  end

  describe "DNSSEC delegation semantics" do
    test "key tag identifies DNSKEY record" do
      # Key tag is calculated from the DNSKEY RDATA
      record = DS.new({12345, 8, 2, <<1, 2, 3>>})
      {key_tag, _, _, _} = record.data
      assert key_tag == 12345
    end

    test "algorithm 8 is RSA/SHA-256" do
      record = DS.new({12345, 8, 2, <<1, 2, 3>>})
      {_, algorithm, _, _} = record.data
      assert algorithm == 8
    end

    test "algorithm 13 is ECDSA P-256" do
      record = DS.new({12345, 13, 2, <<1, 2, 3>>})
      {_, algorithm, _, _} = record.data
      assert algorithm == 13
    end

    test "algorithm 15 is Ed25519" do
      record = DS.new({12345, 15, 2, <<1, 2, 3>>})
      {_, algorithm, _, _} = record.data
      assert algorithm == 15
    end

    test "digest type 1 is SHA-1" do
      digest = :binary.copy(<<1>>, 20)
      record = DS.new({12345, 8, 1, digest})
      {_, _, digest_type, _} = record.data
      assert digest_type == 1
    end

    test "digest type 2 is SHA-256" do
      digest = :binary.copy(<<1>>, 32)
      record = DS.new({12345, 8, 2, digest})
      {_, _, digest_type, _} = record.data
      assert digest_type == 2
    end

    test "digest type 4 is SHA-384" do
      digest = :binary.copy(<<1>>, 48)
      record = DS.new({12345, 8, 4, digest})
      {_, _, digest_type, _} = record.data
      assert digest_type == 4
    end

    test "DS links parent zone to child DNSKEY" do
      # DS record is stored in PARENT zone
      # It contains hash of child's DNSKEY
      key_tag = 12345
      algorithm = 8
      digest_type = 2
      # This would be SHA-256(DNSKEY owner || DNSKEY RDATA)
      digest = :binary.copy(<<0xAB>>, 32)

      record = DS.new({key_tag, algorithm, digest_type, digest})
      assert record.type.value == <<43::16>>
    end
  end

  describe "common configurations" do
    test "RSA/SHA-256 with SHA-256 digest" do
      digest = :binary.copy(<<0x11>>, 32)
      record = DS.new({12345, 8, 2, digest})
      {_, alg, dt, _} = record.data
      assert alg == 8
      assert dt == 2
    end

    test "ECDSA P-256 with SHA-256 digest" do
      digest = :binary.copy(<<0x22>>, 32)
      record = DS.new({12345, 13, 2, digest})
      {_, alg, dt, _} = record.data
      assert alg == 13
      assert dt == 2
    end

    test "Ed25519 with SHA-256 digest" do
      digest = :binary.copy(<<0x33>>, 32)
      record = DS.new({12345, 15, 2, digest})
      {_, alg, dt, _} = record.data
      assert alg == 15
      assert dt == 2
    end

    test "RSA/SHA-256 with SHA-384 digest (higher security)" do
      digest = :binary.copy(<<0x44>>, 48)
      record = DS.new({12345, 8, 4, digest})
      {_, alg, dt, _} = record.data
      assert alg == 8
      assert dt == 4
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = DS.new({12345, 8, 2, <<1, 2, 3>>})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "maximum key tag value" do
      record = DS.new({65535, 8, 2, <<1, 2, 3>>})
      {key_tag, _, _, _} = record.data
      assert key_tag == 65535
    end

    test "minimum key tag value" do
      record = DS.new({0, 8, 2, <<1, 2, 3>>})
      {key_tag, _, _, _} = record.data
      assert key_tag == 0
    end

    test "maximum algorithm value" do
      record = DS.new({12345, 255, 2, <<1, 2, 3>>})
      {_, algorithm, _, _} = record.data
      assert algorithm == 255
    end

    test "maximum digest type value" do
      record = DS.new({12345, 8, 255, <<1, 2, 3>>})
      {_, _, digest_type, _} = record.data
      assert digest_type == 255
    end

    test "empty digest" do
      record = DS.new({12345, 8, 2, <<>>})
      {_, _, _, digest} = record.data
      assert digest == <<>>
    end

    test "large digest (64 bytes)" do
      digest = :binary.copy(<<0xFF>>, 64)
      record = DS.new({12345, 8, 2, digest})
      {_, _, _, d} = record.data
      assert byte_size(d) == 64
    end

    test "all zeros" do
      record = DS.new({0, 0, 0, <<0, 0, 0, 0>>})
      {kt, alg, dt, dig} = record.data
      assert kt == 0
      assert alg == 0
      assert dt == 0
      assert dig == <<0, 0, 0, 0>>
    end
  end
end
