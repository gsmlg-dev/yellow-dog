defmodule DNS.Message.Record.Data.NSEC3Test do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.NSEC3.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with 6-element tuple
  - from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 5155)
  - NSEC3 hashed denial of existence semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.NSEC3

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(NSEC3)
    end

    test "exports new/1" do
      Code.ensure_loaded!(NSEC3)
      assert Kernel.function_exported?(NSEC3, :new, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(NSEC3)
      assert Kernel.function_exported?(NSEC3, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(NSEC3)
      assert is_struct(NSEC3.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %NSEC3{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %NSEC3{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %NSEC3{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %NSEC3{}
      assert Map.has_key?(record, :data)
    end

    test "default type is NSEC3 (50)" do
      type = %NSEC3{}.type
      assert type == DNS.ResourceRecordType.new(50)
    end

    test "default raw is nil" do
      assert %NSEC3{}.raw == nil
    end

    test "default data is nil" do
      assert %NSEC3{}.data == nil
    end
  end

  describe "new/1" do
    test "creates NSEC3 record from 6-element tuple" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>
      next_hashed_owner_name = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      type_bit_maps = <<0x00, 0x06, 0x40>>

      record = NSEC3.new({hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps})
      assert %NSEC3{} = record
    end

    test "stores hash algorithm" do
      record = NSEC3.new({1, 0, 10, <<>>, "ABC", <<>>})
      {hash_alg, _, _, _, _, _} = record.data
      assert hash_alg == 1
    end

    test "stores flags" do
      record = NSEC3.new({1, 1, 10, <<>>, "ABC", <<>>})
      {_, flags, _, _, _, _} = record.data
      assert flags == 1
    end

    test "stores iterations" do
      record = NSEC3.new({1, 0, 100, <<>>, "ABC", <<>>})
      {_, _, iterations, _, _, _} = record.data
      assert iterations == 100
    end

    test "stores salt" do
      salt = <<0xAB, 0xCD, 0xEF>>
      record = NSEC3.new({1, 0, 10, salt, "ABC", <<>>})
      {_, _, _, s, _, _} = record.data
      assert s == salt
    end

    test "stores next hashed owner name" do
      next_hash = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      record = NSEC3.new({1, 0, 10, <<>>, next_hash, <<>>})
      {_, _, _, _, nhon, _} = record.data
      assert nhon == next_hash
    end

    test "stores type bit maps" do
      type_bit_maps = <<0x00, 0x06, 0x40>>
      record = NSEC3.new({1, 0, 10, <<>>, "ABC", type_bit_maps})
      {_, _, _, _, _, tbm} = record.data
      assert tbm == type_bit_maps
    end

    test "raw field contains binary data" do
      record = NSEC3.new({1, 0, 10, <<0xAB>>, "ABC", <<0x00>>})
      assert is_binary(record.raw)
    end

    test "rdlength matches raw size" do
      record = NSEC3.new({1, 0, 10, <<0xAB, 0xCD>>, "ABC", <<0x00, 0x01>>})
      assert record.rdlength == byte_size(record.raw)
    end

    test "raw format includes salt length" do
      salt = <<0xAB, 0xCD>>
      record = NSEC3.new({1, 0, 10, salt, "A", <<>>})
      <<_hash_alg::8, _flags::8, _iter::16, salt_len::8, _rest::binary>> = record.raw
      assert salt_len == 2
    end

    test "raw format includes hash length" do
      next_hash = "ABCDEF"
      record = NSEC3.new({1, 0, 10, <<>>, next_hash, <<>>})
      <<_hash_alg::8, _flags::8, _iter::16, 0::8, hash_len::8, _rest::binary>> = record.raw
      assert hash_len == 6
    end

    test "handles NSEC3 record without salt" do
      record = NSEC3.new({1, 1, 0, <<>>, "HASH", <<0x00, 0x01>>})
      {_, flags, iterations, salt, _, _} = record.data
      assert flags == 1
      assert iterations == 0
      assert salt == <<>>
    end

    test "handles NSEC3 record with longer salt" do
      salt = :binary.copy(<<0x12, 0x34>>, 16)
      record = NSEC3.new({1, 0, 100, salt, "HASH", <<>>})
      {_, _, _, s, _, _} = record.data
      assert byte_size(s) == 32
    end

    test "handles minimal NSEC3 record" do
      record = NSEC3.new({0, 0, 0, <<>>, "", <<>>})
      assert %NSEC3{} = record
      assert record.type.value == <<50::16>>
    end
  end

  describe "from_iodata/2" do
    test "parses NSEC3 from binary" do
      hash_algorithm = 1
      flags = 0
      iterations = 10
      salt = <<0xAB, 0xCD>>
      next_hash = "GJEB7TG3"
      type_bit_maps = <<0x00, 0x06, 0x40>>

      raw = <<
        hash_algorithm::8,
        flags::8,
        iterations::16,
        byte_size(salt)::8,
        salt::binary,
        byte_size(next_hash)::8,
        next_hash::binary,
        type_bit_maps::binary
      >>

      record = NSEC3.from_iodata(raw)
      assert %NSEC3{} = record
    end

    test "parses hash algorithm correctly" do
      raw = <<2::8, 0::8, 10::16, 0::8, 4::8, "HASH", 0x00, 0x01>>
      record = NSEC3.from_iodata(raw)
      {hash_alg, _, _, _, _, _} = record.data
      assert hash_alg == 2
    end

    test "parses flags correctly" do
      raw = <<1::8, 1::8, 10::16, 0::8, 4::8, "HASH", 0x00, 0x01>>
      record = NSEC3.from_iodata(raw)
      {_, flags, _, _, _, _} = record.data
      assert flags == 1
    end

    test "parses iterations correctly" do
      raw = <<1::8, 0::8, 500::16, 0::8, 4::8, "HASH", 0x00, 0x01>>
      record = NSEC3.from_iodata(raw)
      {_, _, iterations, _, _, _} = record.data
      assert iterations == 500
    end

    test "parses salt correctly" do
      salt = <<0xAB, 0xCD, 0xEF>>
      raw = <<1::8, 0::8, 10::16, 3::8, salt::binary, 4::8, "HASH", 0x00>>
      record = NSEC3.from_iodata(raw)
      {_, _, _, s, _, _} = record.data
      assert s == salt
    end

    test "parses next hashed owner name correctly" do
      next_hash = "ABCDEFGH"
      raw = <<1::8, 0::8, 10::16, 0::8, 8::8, next_hash::binary, 0x00>>
      record = NSEC3.from_iodata(raw)
      {_, _, _, _, nhon, _} = record.data
      assert nhon == next_hash
    end

    test "parses type bit maps correctly" do
      type_bit_maps = <<0x00, 0x06, 0x40, 0x01>>
      raw = <<1::8, 0::8, 10::16, 0::8, 4::8, "HASH", type_bit_maps::binary>>
      record = NSEC3.from_iodata(raw)
      {_, _, _, _, _, tbm} = record.data
      assert tbm == type_bit_maps
    end

    test "stores raw binary" do
      raw = <<1::8, 0::8, 10::16, 0::8, 4::8, "HASH", 0x00, 0x01>>
      record = NSEC3.from_iodata(raw)
      assert record.raw == raw
    end

    test "message parameter can be nil" do
      raw = <<1::8, 0::8, 10::16, 0::8, 4::8, "HASH", 0x00>>
      record = NSEC3.from_iodata(raw, nil)
      assert %NSEC3{} = record
    end

    test "parses NSEC3 with empty salt" do
      raw = <<1::8, 0::8, 0::16, 0::8, 4::8, "HASH", 0x00, 0x01>>
      record = NSEC3.from_iodata(raw)
      {_, _, _, salt, _, _} = record.data
      assert salt == <<>>
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats NSEC3 fields" do
      salt = <<0xAB, 0xCD>>
      next_hash = "GJEB7TG3"
      record = NSEC3.new({1, 0, 10, salt, next_hash, <<0x00, 0x06>>})
      str = to_string(record)
      salt_hex = Base.encode16(salt, case: :lower)
      next_hex = Base.encode16(next_hash, case: :lower)
      assert str == "1 0 10 #{salt_hex} #{next_hex}"
    end

    test "salt is lowercase hex encoded" do
      salt = <<0xAB, 0xCD, 0xEF>>
      record = NSEC3.new({1, 0, 10, salt, "HASH", <<>>})
      str = to_string(record)
      assert str =~ "abcdef"
    end

    test "next hash is lowercase hex encoded" do
      next_hash = <<0x12, 0x34, 0x56>>
      record = NSEC3.new({1, 0, 10, <<>>, next_hash, <<>>})
      str = to_string(record)
      assert str =~ "123456"
    end

    test "string interpolation works" do
      record = NSEC3.new({1, 0, 10, <<0xAB>>, "HASH", <<>>})
      result = "NSEC3: #{record}"
      assert result =~ "NSEC3:"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      salt = <<0xAB, 0xCD>>
      next_hash = "GJEB7TG3"
      type_bit_maps = <<0x00, 0x06, 0x40>>
      record = NSEC3.new({1, 0, 10, salt, next_hash, type_bit_maps})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length > 0
    end

    test "length prefix matches content" do
      record = NSEC3.new({1, 0, 10, <<0xAB>>, "HASH", <<0x00, 0x01>>})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, rest::binary>> = iodata
      assert length == byte_size(rest)
    end

    test "wire format has correct structure" do
      salt = <<0xAB, 0xCD>>
      next_hash = "HASH"
      type_bit_maps = <<0x00, 0x01>>
      record = NSEC3.new({1, 0, 10, salt, next_hash, type_bit_maps})
      iodata = DNS.Parameter.to_iodata(record)

      expected_size = 1 + 1 + 2 + 1 + byte_size(salt) + 1 + byte_size(next_hash) + byte_size(type_bit_maps)
      <<length::16, _rest::binary>> = iodata
      assert length == expected_size
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back preserves data" do
      salt = <<0xAB, 0xCD>>
      next_hash = "GJEB7TG3"
      type_bit_maps = <<0x00, 0x06, 0x40>>

      original = NSEC3.new({1, 0, 10, salt, next_hash, type_bit_maps})
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = NSEC3.from_iodata(raw)

      assert parsed.data == {1, 0, 10, salt, next_hash, type_bit_maps}
    end

    test "round-trip preserves different configurations" do
      test_cases = [
        {1, 0, 0, <<>>, "A", <<>>},
        {1, 1, 100, <<0xAB>>, "ABCDEFGH", <<0x00, 0x01>>},
        {2, 0, 1000, <<0x12, 0x34, 0x56>>, "HASH", <<0x00, 0x06, 0x40>>}
      ]

      for {ha, f, i, s, nh, tbm} <- test_cases do
        original = NSEC3.new({ha, f, i, s, nh, tbm})
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
        parsed = NSEC3.from_iodata(raw)
        assert parsed.data == {ha, f, i, s, nh, tbm}
      end
    end
  end

  describe "NSEC3 semantics" do
    test "hash algorithm 1 is SHA-1" do
      record = NSEC3.new({1, 0, 10, <<>>, "HASH", <<>>})
      {hash_alg, _, _, _, _, _} = record.data
      assert hash_alg == 1
    end

    test "opt-out flag is bit 0" do
      # Opt-out flag set
      record = NSEC3.new({1, 1, 10, <<>>, "HASH", <<>>})
      {_, flags, _, _, _, _} = record.data
      assert flags == 1
    end

    test "iterations count for hashing" do
      record = NSEC3.new({1, 0, 50, <<>>, "HASH", <<>>})
      {_, _, iterations, _, _, _} = record.data
      assert iterations == 50
    end

    test "salt adds randomness to hashes" do
      salt = <<0xDE, 0xAD, 0xBE, 0xEF>>
      record = NSEC3.new({1, 0, 10, salt, "HASH", <<>>})
      {_, _, _, s, _, _} = record.data
      assert s == salt
    end

    test "next hashed owner name chains NSEC3 records" do
      next_hash = "GJEB7TG3VGQ3TQEGK7VJ9K3CD7A6T9T9"
      record = NSEC3.new({1, 0, 10, <<>>, next_hash, <<>>})
      {_, _, _, _, nhon, _} = record.data
      assert nhon == next_hash
    end

    test "type bit maps indicate present record types" do
      # Bitmap for A and AAAA records
      type_bit_maps = <<0x00, 0x06, 0x40>>
      record = NSEC3.new({1, 0, 10, <<>>, "HASH", type_bit_maps})
      {_, _, _, _, _, tbm} = record.data
      assert tbm == type_bit_maps
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = NSEC3.new({1, 0, 10, <<0xAB>>, "HASH", <<>>})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "maximum iterations" do
      record = NSEC3.new({1, 0, 65535, <<>>, "HASH", <<>>})
      {_, _, iterations, _, _, _} = record.data
      assert iterations == 65535
    end

    test "maximum salt length (255 bytes)" do
      salt = :binary.copy(<<0xAA>>, 255)
      record = NSEC3.new({1, 0, 10, salt, "H", <<>>})
      {_, _, _, s, _, _} = record.data
      assert byte_size(s) == 255
    end

    test "maximum hash length (255 bytes)" do
      next_hash = :binary.copy(<<0xBB>>, 255)
      record = NSEC3.new({1, 0, 10, <<>>, next_hash, <<>>})
      {_, _, _, _, nhon, _} = record.data
      assert byte_size(nhon) == 255
    end

    test "empty type bit maps" do
      record = NSEC3.new({1, 0, 10, <<>>, "HASH", <<>>})
      {_, _, _, _, _, tbm} = record.data
      assert tbm == <<>>
    end

    test "maximum flags value" do
      record = NSEC3.new({1, 255, 10, <<>>, "HASH", <<>>})
      {_, flags, _, _, _, _} = record.data
      assert flags == 255
    end

    test "all zeros" do
      record = NSEC3.new({0, 0, 0, <<>>, "", <<>>})
      {ha, f, i, s, nh, tbm} = record.data
      assert {ha, f, i, s, nh, tbm} == {0, 0, 0, <<>>, "", <<>>}
    end
  end
end
