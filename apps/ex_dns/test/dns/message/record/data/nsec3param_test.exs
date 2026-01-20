defmodule DNS.Message.Record.Data.NSEC3PARAMTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.NSEC3PARAM.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with 4-element tuple
  - from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 5155)
  - NSEC3 parameter semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.NSEC3PARAM

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(NSEC3PARAM)
    end

    test "exports new/1" do
      Code.ensure_loaded!(NSEC3PARAM)
      assert Kernel.function_exported?(NSEC3PARAM, :new, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(NSEC3PARAM)
      assert Kernel.function_exported?(NSEC3PARAM, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(NSEC3PARAM)
      assert is_struct(NSEC3PARAM.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %NSEC3PARAM{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %NSEC3PARAM{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %NSEC3PARAM{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %NSEC3PARAM{}
      assert Map.has_key?(record, :data)
    end

    test "default type is NSEC3PARAM (51)" do
      type = %NSEC3PARAM{}.type
      assert type == DNS.ResourceRecordType.new(51)
    end

    test "default raw is nil" do
      assert %NSEC3PARAM{}.raw == nil
    end

    test "default data is nil" do
      assert %NSEC3PARAM{}.data == nil
    end
  end

  describe "new/1" do
    test "creates NSEC3PARAM record from 4-element tuple" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>

      record = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})
      assert %NSEC3PARAM{} = record
      assert record.data == {hash_algorithm, flags, iterations, salt}
    end

    test "stores hash algorithm" do
      record = NSEC3PARAM.new({1, 0, 10, <<>>})
      {hash_alg, _, _, _} = record.data
      assert hash_alg == 1
    end

    test "stores flags" do
      record = NSEC3PARAM.new({1, 1, 10, <<>>})
      {_, flags, _, _} = record.data
      assert flags == 1
    end

    test "stores iterations" do
      record = NSEC3PARAM.new({1, 0, 100, <<>>})
      {_, _, iterations, _} = record.data
      assert iterations == 100
    end

    test "stores salt" do
      salt = <<0xAB, 0xCD, 0xEF>>
      record = NSEC3PARAM.new({1, 0, 10, salt})
      {_, _, _, s} = record.data
      assert s == salt
    end

    test "raw field contains binary data" do
      record = NSEC3PARAM.new({1, 0, 10, <<0xAB>>})
      assert is_binary(record.raw)
    end

    test "rdlength is 5 + salt size" do
      salt = <<0xAB, 0xCD>>
      record = NSEC3PARAM.new({1, 0, 10, salt})
      # 1 (hash_alg) + 1 (flags) + 2 (iterations) + 1 (salt_len) + 2 (salt) = 7
      assert record.rdlength == 7
    end

    test "raw format includes salt length" do
      salt = <<0xAB, 0xCD>>
      record = NSEC3PARAM.new({1, 0, 10, salt})
      <<_hash_alg::8, _flags::8, _iter::16, salt_len::8, _rest::binary>> = record.raw
      assert salt_len == 2
    end

    test "raw format is correct" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>

      record = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})
      expected_raw = <<hash_algorithm::8, flags::8, iterations::16, byte_size(salt)::8, salt::binary>>
      assert record.raw == expected_raw
    end

    test "handles NSEC3PARAM without salt" do
      record = NSEC3PARAM.new({1, 0, 0, <<>>})
      {_, _, _, salt} = record.data
      assert salt == <<>>
      # 1 + 1 + 2 + 1 + 0 = 5
      assert record.rdlength == 5
    end

    test "handles NSEC3PARAM with longer salt" do
      salt = :binary.copy(<<0x12, 0x34>>, 16)
      record = NSEC3PARAM.new({1, 1, 100, salt})
      {_, _, _, s} = record.data
      assert byte_size(s) == 32
      assert record.rdlength == 1 + 1 + 2 + 1 + 32
    end

    test "handles minimal NSEC3PARAM record" do
      record = NSEC3PARAM.new({0, 0, 0, <<>>})
      assert %NSEC3PARAM{} = record
      assert record.type.value == <<51::16>>
    end
  end

  describe "from_iodata/2" do
    test "parses NSEC3PARAM from binary" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>

      raw = <<hash_algorithm::8, flags::8, iterations::16, byte_size(salt)::8, salt::binary>>
      record = NSEC3PARAM.from_iodata(raw)
      assert %NSEC3PARAM{} = record
    end

    test "parses hash algorithm correctly" do
      raw = <<2::8, 0::8, 10::16, 0::8>>
      record = NSEC3PARAM.from_iodata(raw)
      {hash_alg, _, _, _} = record.data
      assert hash_alg == 2
    end

    test "parses flags correctly" do
      raw = <<1::8, 1::8, 10::16, 0::8>>
      record = NSEC3PARAM.from_iodata(raw)
      {_, flags, _, _} = record.data
      assert flags == 1
    end

    test "parses iterations correctly" do
      raw = <<1::8, 0::8, 500::16, 0::8>>
      record = NSEC3PARAM.from_iodata(raw)
      {_, _, iterations, _} = record.data
      assert iterations == 500
    end

    test "parses salt correctly" do
      salt = <<0xAB, 0xCD, 0xEF>>
      raw = <<1::8, 0::8, 10::16, 3::8, salt::binary>>
      record = NSEC3PARAM.from_iodata(raw)
      {_, _, _, s} = record.data
      assert s == salt
    end

    test "stores raw binary" do
      raw = <<1::8, 0::8, 10::16, 2::8, 0xAB, 0xCD>>
      record = NSEC3PARAM.from_iodata(raw)
      assert record.raw == raw
    end

    test "sets rdlength from raw size" do
      raw = <<1::8, 0::8, 10::16, 2::8, 0xAB, 0xCD>>
      record = NSEC3PARAM.from_iodata(raw)
      assert record.rdlength == byte_size(raw)
    end

    test "message parameter can be nil" do
      raw = <<1::8, 0::8, 10::16, 0::8>>
      record = NSEC3PARAM.from_iodata(raw, nil)
      assert %NSEC3PARAM{} = record
    end

    test "parses NSEC3PARAM with empty salt" do
      raw = <<1::8, 0::8, 0::16, 0::8>>
      record = NSEC3PARAM.from_iodata(raw)
      {_, _, _, salt} = record.data
      assert salt == <<>>
    end

    test "parses NSEC3PARAM with different parameters" do
      raw = <<2::8, 1::8, 100::16, 4::8, 0x01, 0x02, 0x03, 0x04>>
      record = NSEC3PARAM.from_iodata(raw)
      {hash_alg, flags, iterations, salt} = record.data
      assert hash_alg == 2
      assert flags == 1
      assert iterations == 100
      assert salt == <<0x01, 0x02, 0x03, 0x04>>
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'hash_algorithm flags iterations salt_hex'" do
      salt = <<0xAB, 0xCD>>
      record = NSEC3PARAM.new({1, 0, 10, salt})
      str = to_string(record)
      salt_hex = Base.encode16(salt, case: :lower)
      assert str == "1 0 10 #{salt_hex}"
    end

    test "salt is lowercase hex encoded" do
      salt = <<0xAB, 0xCD, 0xEF>>
      record = NSEC3PARAM.new({1, 0, 10, salt})
      str = to_string(record)
      assert str =~ "abcdef"
    end

    test "string interpolation works" do
      record = NSEC3PARAM.new({1, 0, 10, <<0xAB>>})
      result = "NSEC3PARAM: #{record}"
      assert result =~ "NSEC3PARAM:"
    end

    test "empty salt produces empty hex" do
      record = NSEC3PARAM.new({1, 0, 0, <<>>})
      str = to_string(record)
      assert str == "1 0 0 "
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      salt = <<0xAB, 0xCD>>
      record = NSEC3PARAM.new({1, 0, 10, salt})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length == 1 + 1 + 2 + 1 + 2
    end

    test "length prefix matches content" do
      salt = <<0xAB, 0xCD>>
      record = NSEC3PARAM.new({1, 0, 10, salt})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, rest::binary>> = iodata
      assert length == byte_size(rest)
    end

    test "wire format has correct structure" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>

      record = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})
      iodata = DNS.Parameter.to_iodata(record)

      expected_size = 1 + 1 + 2 + 1 + byte_size(salt)
      expected = <<expected_size::16, hash_algorithm::8, flags::8, iterations::16, byte_size(salt)::8, salt::binary>>
      assert iodata == expected
    end

    test "converts NSEC3PARAM without salt to iodata" do
      record = NSEC3PARAM.new({1, 0, 0, <<>>})
      iodata = DNS.Parameter.to_iodata(record)
      expected = <<5::16, 1::8, 0::8, 0::16, 0::8>>
      assert iodata == expected
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back preserves data" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>

      original = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = NSEC3PARAM.from_iodata(raw)

      assert parsed.data == {hash_algorithm, flags, iterations, salt}
    end

    test "round-trip preserves different configurations" do
      test_cases = [
        {1, 0, 0, <<>>},
        {1, 1, 100, <<0xAB>>},
        {2, 0, 1000, <<0x12, 0x34, 0x56, 0x78>>}
      ]

      for {ha, f, i, s} <- test_cases do
        original = NSEC3PARAM.new({ha, f, i, s})
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
        parsed = NSEC3PARAM.from_iodata(raw)
        assert parsed.data == {ha, f, i, s}
      end
    end
  end

  describe "NSEC3 parameter semantics" do
    test "hash algorithm 1 is SHA-1" do
      record = NSEC3PARAM.new({1, 0, 10, <<>>})
      {hash_alg, _, _, _} = record.data
      assert hash_alg == 1
    end

    test "flags should be 0 for NSEC3PARAM" do
      # Per RFC 5155, flags field should be 0
      record = NSEC3PARAM.new({1, 0, 10, <<>>})
      {_, flags, _, _} = record.data
      assert flags == 0
    end

    test "iterations count for hashing" do
      record = NSEC3PARAM.new({1, 0, 50, <<>>})
      {_, _, iterations, _} = record.data
      assert iterations == 50
    end

    test "salt adds randomness to hashes" do
      salt = <<0xDE, 0xAD, 0xBE, 0xEF>>
      record = NSEC3PARAM.new({1, 0, 10, salt})
      {_, _, _, s} = record.data
      assert s == salt
    end

    test "NSEC3PARAM provides zone signing parameters" do
      # NSEC3PARAM is at zone apex and defines parameters for all NSEC3 records
      record = NSEC3PARAM.new({1, 0, 10, <<0xAB, 0xCD>>})
      assert record.type.value == <<51::16>>
    end

    test "parameters match NSEC3 records in zone" do
      # Same parameters used in NSEC3PARAM should be in NSEC3 records
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>

      record = NSEC3PARAM.new({hash_algorithm, flags, iterations, salt})
      {ha, f, i, s} = record.data
      assert ha == hash_algorithm
      assert f == flags
      assert i == iterations
      assert s == salt
    end
  end

  describe "recommended configurations" do
    test "minimal iterations (0) for performance" do
      record = NSEC3PARAM.new({1, 0, 0, <<>>})
      {_, _, iterations, _} = record.data
      assert iterations == 0
    end

    test "moderate iterations (10) for balance" do
      record = NSEC3PARAM.new({1, 0, 10, <<>>})
      {_, _, iterations, _} = record.data
      assert iterations == 10
    end

    test "no salt (current recommendation)" do
      # Modern recommendation is to use empty salt
      record = NSEC3PARAM.new({1, 0, 0, <<>>})
      {_, _, _, salt} = record.data
      assert salt == <<>>
    end

    test "short salt (legacy)" do
      # Legacy configurations might use short salts
      salt = <<0xAB, 0xCD>>
      record = NSEC3PARAM.new({1, 0, 10, salt})
      {_, _, _, s} = record.data
      assert byte_size(s) == 2
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = NSEC3PARAM.new({1, 0, 10, <<0xAB>>})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "maximum hash algorithm value" do
      record = NSEC3PARAM.new({255, 0, 10, <<>>})
      {hash_alg, _, _, _} = record.data
      assert hash_alg == 255
    end

    test "maximum flags value" do
      record = NSEC3PARAM.new({1, 255, 10, <<>>})
      {_, flags, _, _} = record.data
      assert flags == 255
    end

    test "maximum iterations" do
      record = NSEC3PARAM.new({1, 0, 65535, <<>>})
      {_, _, iterations, _} = record.data
      assert iterations == 65535
    end

    test "maximum salt length (255 bytes)" do
      salt = :binary.copy(<<0xAA>>, 255)
      record = NSEC3PARAM.new({1, 0, 10, salt})
      {_, _, _, s} = record.data
      assert byte_size(s) == 255
    end

    test "all zeros" do
      record = NSEC3PARAM.new({0, 0, 0, <<>>})
      {ha, f, i, s} = record.data
      assert {ha, f, i, s} == {0, 0, 0, <<>>}
    end

    test "all maximum values with salt" do
      salt = <<0xFF, 0xFF>>
      record = NSEC3PARAM.new({255, 255, 65535, salt})
      {ha, f, i, s} = record.data
      assert ha == 255
      assert f == 255
      assert i == 65535
      assert s == salt
    end
  end
end
