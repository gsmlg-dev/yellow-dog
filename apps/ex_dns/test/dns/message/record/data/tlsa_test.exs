defmodule DNS.Message.Record.Data.TLSATest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.TLSA.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with {usage, selector, matching_type, cert_data} tuple
  - from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 6698)
  - DANE certificate semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.TLSA

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(TLSA)
    end

    test "exports new/1" do
      Code.ensure_loaded!(TLSA)
      assert Kernel.function_exported?(TLSA, :new, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(TLSA)
      assert Kernel.function_exported?(TLSA, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(TLSA)
      assert is_struct(TLSA.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %TLSA{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %TLSA{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %TLSA{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %TLSA{}
      assert Map.has_key?(record, :data)
    end

    test "default type is TLSA (52)" do
      type = %TLSA{}.type
      assert type == DNS.ResourceRecordType.new(52)
    end

    test "default raw is nil" do
      assert %TLSA{}.raw == nil
    end

    test "default data is nil" do
      assert %TLSA{}.data == nil
    end
  end

  describe "new/1" do
    test "creates TLSA record from 4-element tuple" do
      # DANE-EE (3), SPKI (1), SHA-256 (1)
      cert_data = :crypto.strong_rand_bytes(32)
      record = TLSA.new({3, 1, 1, cert_data})
      assert %TLSA{} = record
    end

    test "stores usage field" do
      cert_data = <<1, 2, 3, 4>>
      record = TLSA.new({3, 1, 1, cert_data})
      {usage, _, _, _} = record.data
      assert usage == 3
    end

    test "stores selector field" do
      cert_data = <<1, 2, 3, 4>>
      record = TLSA.new({3, 1, 1, cert_data})
      {_, selector, _, _} = record.data
      assert selector == 1
    end

    test "stores matching_type field" do
      cert_data = <<1, 2, 3, 4>>
      record = TLSA.new({3, 1, 1, cert_data})
      {_, _, matching_type, _} = record.data
      assert matching_type == 1
    end

    test "stores cert_data field" do
      cert_data = <<1, 2, 3, 4>>
      record = TLSA.new({3, 1, 1, cert_data})
      {_, _, _, data} = record.data
      assert data == cert_data
    end

    test "creates DANE-EE record (usage=3)" do
      cert_data = :binary.copy(<<0xAB>>, 32)
      record = TLSA.new({3, 1, 1, cert_data})
      {usage, _, _, _} = record.data
      assert usage == 3
    end

    test "creates DANE-TA record (usage=2)" do
      cert_data = :binary.copy(<<0xCD>>, 32)
      record = TLSA.new({2, 0, 1, cert_data})
      {usage, _, _, _} = record.data
      assert usage == 2
    end

    test "creates PKIX-TA record (usage=0)" do
      cert_data = :binary.copy(<<0xEF>>, 32)
      record = TLSA.new({0, 0, 1, cert_data})
      {usage, _, _, _} = record.data
      assert usage == 0
    end

    test "creates PKIX-EE record (usage=1)" do
      cert_data = :binary.copy(<<0x12>>, 32)
      record = TLSA.new({1, 0, 1, cert_data})
      {usage, _, _, _} = record.data
      assert usage == 1
    end

    test "creates record with Cert selector (0)" do
      cert_data = :binary.copy(<<0x34>>, 64)
      record = TLSA.new({3, 0, 1, cert_data})
      {_, selector, _, _} = record.data
      assert selector == 0
    end

    test "creates record with SPKI selector (1)" do
      cert_data = :binary.copy(<<0x56>>, 32)
      record = TLSA.new({3, 1, 1, cert_data})
      {_, selector, _, _} = record.data
      assert selector == 1
    end

    test "creates record with Full matching (0)" do
      cert_data = :binary.copy(<<0x78>>, 100)
      record = TLSA.new({3, 0, 0, cert_data})
      {_, _, matching_type, _} = record.data
      assert matching_type == 0
    end

    test "creates record with SHA-256 matching (1)" do
      cert_data = :binary.copy(<<0x9A>>, 32)
      record = TLSA.new({3, 1, 1, cert_data})
      {_, _, matching_type, _} = record.data
      assert matching_type == 1
    end

    test "creates record with SHA-512 matching (2)" do
      cert_data = :binary.copy(<<0xBC>>, 64)
      record = TLSA.new({3, 1, 2, cert_data})
      {_, _, matching_type, _} = record.data
      assert matching_type == 2
    end

    test "raw field contains binary data" do
      cert_data = <<1, 2, 3, 4>>
      record = TLSA.new({3, 1, 1, cert_data})
      assert is_binary(record.raw)
    end

    test "rdlength is 3 + cert_data size" do
      cert_data = :binary.copy(<<0xDE>>, 32)
      record = TLSA.new({3, 1, 1, cert_data})
      assert record.rdlength == 3 + byte_size(cert_data)
    end

    test "handles empty cert_data" do
      record = TLSA.new({0, 0, 0, <<>>})
      {_, _, _, data} = record.data
      assert data == <<>>
      assert record.rdlength == 3
    end
  end

  describe "from_iodata/2" do
    test "parses TLSA from binary" do
      cert_data = :binary.copy(<<0x01>>, 32)
      raw = <<3::8, 1::8, 1::8, cert_data::binary>>
      record = TLSA.from_iodata(raw, nil)
      assert %TLSA{} = record
    end

    test "parses usage correctly" do
      cert_data = <<1, 2, 3, 4>>
      raw = <<2::8, 1::8, 1::8, cert_data::binary>>
      record = TLSA.from_iodata(raw)
      {usage, _, _, _} = record.data
      assert usage == 2
    end

    test "parses selector correctly" do
      cert_data = <<1, 2, 3, 4>>
      raw = <<3::8, 0::8, 1::8, cert_data::binary>>
      record = TLSA.from_iodata(raw)
      {_, selector, _, _} = record.data
      assert selector == 0
    end

    test "parses matching_type correctly" do
      cert_data = <<1, 2, 3, 4>>
      raw = <<3::8, 1::8, 2::8, cert_data::binary>>
      record = TLSA.from_iodata(raw)
      {_, _, matching_type, _} = record.data
      assert matching_type == 2
    end

    test "parses cert_data correctly" do
      cert_data = <<0xAA, 0xBB, 0xCC, 0xDD>>
      raw = <<3::8, 1::8, 1::8, cert_data::binary>>
      record = TLSA.from_iodata(raw)
      {_, _, _, data} = record.data
      assert data == cert_data
    end

    test "stores raw binary" do
      cert_data = <<1, 2, 3, 4>>
      raw = <<3::8, 1::8, 1::8, cert_data::binary>>
      record = TLSA.from_iodata(raw)
      assert record.raw == raw
    end

    test "parses SHA-256 hash (32 bytes)" do
      cert_data = :binary.copy(<<0xAB>>, 32)
      raw = <<3::8, 1::8, 1::8, cert_data::binary>>
      record = TLSA.from_iodata(raw)
      {_, _, _, data} = record.data
      assert byte_size(data) == 32
    end

    test "parses SHA-512 hash (64 bytes)" do
      cert_data = :binary.copy(<<0xCD>>, 64)
      raw = <<3::8, 1::8, 2::8, cert_data::binary>>
      record = TLSA.from_iodata(raw)
      {_, _, _, data} = record.data
      assert byte_size(data) == 64
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'usage selector matching_type hex'" do
      cert_data = <<0x01, 0x02, 0x03, 0x04>>
      record = TLSA.new({3, 1, 1, cert_data})
      str = to_string(record)
      assert str == "3 1 1 01020304"
    end

    test "hex is lowercase" do
      cert_data = <<0xAB, 0xCD, 0xEF>>
      record = TLSA.new({3, 1, 1, cert_data})
      str = to_string(record)
      assert str =~ "abcdef"
    end

    test "string interpolation works" do
      cert_data = <<0xFF>>
      record = TLSA.new({3, 1, 1, cert_data})
      result = "TLSA: #{record}"
      assert result =~ "TLSA:"
      assert result =~ "3 1 1"
    end

    test "formats empty cert_data" do
      record = TLSA.new({0, 0, 0, <<>>})
      str = to_string(record)
      assert str == "0 0 0 "
    end

    test "formats SHA-256 hash correctly" do
      cert_data = :binary.copy(<<0x12>>, 32)
      record = TLSA.new({3, 1, 1, cert_data})
      str = to_string(record)
      hex = Base.encode16(cert_data, case: :lower)
      assert str == "3 1 1 #{hex}"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      cert_data = <<0x01, 0x02, 0x03, 0x04>>
      record = TLSA.new({3, 1, 1, cert_data})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, usage::8, selector::8, matching_type::8, data::binary>> = iodata
      assert length == 7
      assert usage == 3
      assert selector == 1
      assert matching_type == 1
      assert data == cert_data
    end

    test "length prefix matches rdlength" do
      cert_data = :binary.copy(<<0xAB>>, 32)
      record = TLSA.new({3, 1, 1, cert_data})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length == record.rdlength
    end

    test "wire format for empty cert_data" do
      record = TLSA.new({0, 0, 0, <<>>})
      iodata = DNS.Parameter.to_iodata(record)
      assert iodata == <<3::16, 0::8, 0::8, 0::8>>
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      cert_data = :crypto.strong_rand_bytes(32)
      original = TLSA.new({3, 1, 1, cert_data})
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = TLSA.from_iodata(raw)
      assert parsed.data == original.data
    end

    test "round-trip preserves all fields" do
      test_cases = [
        {0, 0, 0, <<>>},
        {1, 0, 1, :binary.copy(<<0xAB>>, 32)},
        {2, 1, 1, :binary.copy(<<0xCD>>, 32)},
        {3, 1, 2, :binary.copy(<<0xEF>>, 64)}
      ]

      for {usage, selector, matching_type, cert_data} <- test_cases do
        original = TLSA.new({usage, selector, matching_type, cert_data})
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
        parsed = TLSA.from_iodata(raw)
        assert parsed.data == {usage, selector, matching_type, cert_data}
      end
    end
  end

  describe "DANE certificate semantics" do
    test "DANE-EE (3) for end-entity certificate" do
      # Domain-issued end-entity certificate
      cert_hash = :binary.copy(<<0x11>>, 32)
      record = TLSA.new({3, 1, 1, cert_hash})
      {usage, _, _, _} = record.data
      assert usage == 3
    end

    test "DANE-TA (2) for trust anchor" do
      # Domain-issued trust anchor
      cert_hash = :binary.copy(<<0x22>>, 32)
      record = TLSA.new({2, 0, 1, cert_hash})
      {usage, _, _, _} = record.data
      assert usage == 2
    end

    test "PKIX-EE (1) for PKIX end-entity" do
      # PKIX end-entity certificate constraint
      cert_hash = :binary.copy(<<0x33>>, 32)
      record = TLSA.new({1, 0, 1, cert_hash})
      {usage, _, _, _} = record.data
      assert usage == 1
    end

    test "PKIX-TA (0) for PKIX trust anchor" do
      # CA constraint (PKIX trust anchor)
      cert_hash = :binary.copy(<<0x44>>, 32)
      record = TLSA.new({0, 0, 1, cert_hash})
      {usage, _, _, _} = record.data
      assert usage == 0
    end

    test "Cert selector (0) uses full certificate" do
      # Full certificate data
      cert_data = :binary.copy(<<0x55>>, 100)
      record = TLSA.new({3, 0, 0, cert_data})
      {_, selector, _, _} = record.data
      assert selector == 0
    end

    test "SPKI selector (1) uses SubjectPublicKeyInfo" do
      # Only the public key info
      spki_hash = :binary.copy(<<0x66>>, 32)
      record = TLSA.new({3, 1, 1, spki_hash})
      {_, selector, _, _} = record.data
      assert selector == 1
    end
  end

  describe "common TLSA configurations" do
    test "DANE-EE SPKI SHA-256 (3 1 1)" do
      # Most common DANE configuration
      hash = :binary.copy(<<0xAA>>, 32)
      record = TLSA.new({3, 1, 1, hash})
      {usage, selector, matching_type, _} = record.data
      assert {usage, selector, matching_type} == {3, 1, 1}
    end

    test "DANE-TA Cert SHA-256 (2 0 1)" do
      # Trust anchor with full cert hash
      hash = :binary.copy(<<0xBB>>, 32)
      record = TLSA.new({2, 0, 1, hash})
      {usage, selector, matching_type, _} = record.data
      assert {usage, selector, matching_type} == {2, 0, 1}
    end

    test "DANE-EE Cert Full (3 0 0)" do
      # Full certificate data (no hash)
      cert = :binary.copy(<<0xCC>>, 500)
      record = TLSA.new({3, 0, 0, cert})
      {usage, selector, matching_type, _} = record.data
      assert {usage, selector, matching_type} == {3, 0, 0}
    end

    test "DANE-EE SPKI SHA-512 (3 1 2)" do
      # SHA-512 hash
      hash = :binary.copy(<<0xDD>>, 64)
      record = TLSA.new({3, 1, 2, hash})
      {usage, selector, matching_type, _} = record.data
      assert {usage, selector, matching_type} == {3, 1, 2}
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      cert_data = <<1, 2, 3, 4>>
      record = TLSA.new({3, 1, 1, cert_data})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "large certificate data" do
      # Full DER certificate can be several KB
      large_cert = :binary.copy(<<0x00>>, 2048)
      record = TLSA.new({3, 0, 0, large_cert})
      {_, _, _, data} = record.data
      assert byte_size(data) == 2048
    end

    test "max usage value (255)" do
      cert_data = <<1, 2, 3, 4>>
      record = TLSA.new({255, 1, 1, cert_data})
      {usage, _, _, _} = record.data
      assert usage == 255
    end

    test "max selector value (255)" do
      cert_data = <<1, 2, 3, 4>>
      record = TLSA.new({3, 255, 1, cert_data})
      {_, selector, _, _} = record.data
      assert selector == 255
    end

    test "max matching_type value (255)" do
      cert_data = <<1, 2, 3, 4>>
      record = TLSA.new({3, 1, 255, cert_data})
      {_, _, matching_type, _} = record.data
      assert matching_type == 255
    end
  end
end
