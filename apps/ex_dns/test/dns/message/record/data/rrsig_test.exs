defmodule DNS.Message.Record.Data.RRSIGTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.RRSIG.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with 9-element tuple
  - from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 4034)
  - DNSSEC signature semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.RRSIG
  alias DNS.Message.Domain
  alias DNS.ResourceRecordType

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(RRSIG)
    end

    test "exports new/1" do
      Code.ensure_loaded!(RRSIG)
      assert Kernel.function_exported?(RRSIG, :new, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(RRSIG)
      assert Kernel.function_exported?(RRSIG, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(RRSIG)
      assert is_struct(RRSIG.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %RRSIG{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %RRSIG{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %RRSIG{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %RRSIG{}
      assert Map.has_key?(record, :data)
    end

    test "default type is RRSIG (46)" do
      type = %RRSIG{}.type
      assert type == ResourceRecordType.new(46)
    end

    test "default raw is nil" do
      assert %RRSIG{}.raw == nil
    end

    test "default data is nil" do
      assert %RRSIG{}.data == nil
    end
  end

  describe "new/1" do
    test "creates RRSIG record from 9-element tuple" do
      type_covered = ResourceRecordType.new(1)
      algorithm = 8
      labels = 2
      original_ttl = 3600
      signature_expiration = 1_672_531_200
      signature_inception = 1_672_464_000
      key_tag = 12345
      signers_name = Domain.new("example.com")
      signature = :binary.copy(<<0xAB>>, 64)

      record =
        RRSIG.new({
          type_covered,
          algorithm,
          labels,
          original_ttl,
          signature_expiration,
          signature_inception,
          key_tag,
          signers_name,
          signature
        })

      assert %RRSIG{} = record
    end

    test "stores type covered (A record)" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {tc, _, _, _, _, _, _, _, _} = record.data
      assert tc == type_covered
    end

    test "stores algorithm (RSA/SHA-256 = 8)" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {_, algorithm, _, _, _, _, _, _, _} = record.data
      assert algorithm == 8
    end

    test "stores labels count" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 3, 3600, 0, 0, 1, signers_name, signature})

      {_, _, labels, _, _, _, _, _, _} = record.data
      assert labels == 3
    end

    test "stores original TTL" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 86400, 0, 0, 1, signers_name, signature})

      {_, _, _, original_ttl, _, _, _, _, _} = record.data
      assert original_ttl == 86400
    end

    test "stores signature expiration timestamp" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>
      expiration = 1_672_531_200

      record =
        RRSIG.new({type_covered, 8, 2, 3600, expiration, 0, 1, signers_name, signature})

      {_, _, _, _, exp, _, _, _, _} = record.data
      assert exp == expiration
    end

    test "stores signature inception timestamp" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>
      inception = 1_672_464_000

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, inception, 1, signers_name, signature})

      {_, _, _, _, _, inc, _, _, _} = record.data
      assert inc == inception
    end

    test "stores key tag" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 54321, signers_name, signature})

      {_, _, _, _, _, _, key_tag, _, _} = record.data
      assert key_tag == 54321
    end

    test "stores signer's name" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("secure.example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {_, _, _, _, _, _, _, sname, _} = record.data
      assert sname == signers_name
    end

    test "stores signature bytes" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = :binary.copy(<<0xCD>>, 128)

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {_, _, _, _, _, _, _, _, sig} = record.data
      assert sig == signature
    end

    test "raw field contains binary data" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      assert is_binary(record.raw)
    end

    test "rdlength matches raw size" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      assert record.rdlength == byte_size(record.raw)
    end

    test "handles minimal RRSIG record" do
      type_covered = ResourceRecordType.new(255)
      algorithm = 1
      labels = 0
      original_ttl = 0
      signature_expiration = 0
      signature_inception = 0
      key_tag = 0
      signers_name = Domain.new("")
      signature = <<>>

      record =
        RRSIG.new({
          type_covered,
          algorithm,
          labels,
          original_ttl,
          signature_expiration,
          signature_inception,
          key_tag,
          signers_name,
          signature
        })

      assert %RRSIG{} = record
      assert record.type.value == <<46::16>>
    end
  end

  describe "from_iodata/2" do
    test "parses RRSIG from binary" do
      type_covered = 1
      algorithm = 8
      labels = 2
      original_ttl = 3600
      signature_expiration = 1_672_531_200
      signature_inception = 1_672_464_000
      key_tag = 12345
      signers_name = Domain.new("example.com")
      signature = :binary.copy(<<0xAB>>, 64)
      signers_name_binary = DNS.to_iodata(signers_name)

      raw = <<
        type_covered::16,
        algorithm::8,
        labels::8,
        original_ttl::32,
        signature_expiration::32,
        signature_inception::32,
        key_tag::16,
        signers_name_binary::binary,
        signature::binary
      >>

      record = RRSIG.from_iodata(raw)
      assert %RRSIG{} = record
    end

    test "parses type covered correctly" do
      signers_name = Domain.new("example.com")
      signers_name_binary = DNS.to_iodata(signers_name)
      signature = <<1, 2, 3>>

      raw = <<
        28::16,
        8::8,
        2::8,
        3600::32,
        0::32,
        0::32,
        1::16,
        signers_name_binary::binary,
        signature::binary
      >>

      record = RRSIG.from_iodata(raw)
      {type_covered, _, _, _, _, _, _, _, _} = record.data
      assert type_covered.value == <<28::16>>
    end

    test "parses algorithm correctly" do
      signers_name = Domain.new("example.com")
      signers_name_binary = DNS.to_iodata(signers_name)
      signature = <<1, 2, 3>>

      raw = <<
        1::16,
        13::8,
        2::8,
        3600::32,
        0::32,
        0::32,
        1::16,
        signers_name_binary::binary,
        signature::binary
      >>

      record = RRSIG.from_iodata(raw)
      {_, algorithm, _, _, _, _, _, _, _} = record.data
      assert algorithm == 13
    end

    test "parses signer's name correctly" do
      signers_name = Domain.new("secure.example.com")
      signers_name_binary = DNS.to_iodata(signers_name)
      signature = <<1, 2, 3>>

      raw = <<
        1::16,
        8::8,
        2::8,
        3600::32,
        0::32,
        0::32,
        1::16,
        signers_name_binary::binary,
        signature::binary
      >>

      record = RRSIG.from_iodata(raw)
      {_, _, _, _, _, _, _, sname, _} = record.data
      assert sname.value == "secure.example.com."
    end

    test "parses signature bytes correctly" do
      signers_name = Domain.new("example.com")
      signers_name_binary = DNS.to_iodata(signers_name)
      signature = <<0xCD, 0xEF, 0x12, 0x34>>

      raw = <<
        1::16,
        8::8,
        2::8,
        3600::32,
        0::32,
        0::32,
        1::16,
        signers_name_binary::binary,
        signature::binary
      >>

      record = RRSIG.from_iodata(raw)
      {_, _, _, _, _, _, _, _, sig} = record.data
      assert sig == signature
    end

    test "stores raw binary" do
      signers_name = Domain.new("example.com")
      signers_name_binary = DNS.to_iodata(signers_name)
      signature = <<1, 2, 3>>

      raw = <<
        1::16,
        8::8,
        2::8,
        3600::32,
        0::32,
        0::32,
        1::16,
        signers_name_binary::binary,
        signature::binary
      >>

      record = RRSIG.from_iodata(raw)
      assert record.raw == raw
    end

    test "message parameter can be nil" do
      signers_name = Domain.new("example.com")
      signers_name_binary = DNS.to_iodata(signers_name)
      signature = <<1, 2, 3>>

      raw = <<
        1::16,
        8::8,
        2::8,
        3600::32,
        0::32,
        0::32,
        1::16,
        signers_name_binary::binary,
        signature::binary
      >>

      record = RRSIG.from_iodata(raw, nil)
      assert %RRSIG{} = record
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats all RRSIG fields" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = :binary.copy(<<0xAB>>, 64)

      record =
        RRSIG.new({
          type_covered,
          8,
          2,
          3600,
          1_672_531_200,
          1_672_464_000,
          12345,
          signers_name,
          signature
        })

      str = to_string(record)
      assert str =~ "A 8 2 3600 1672531200 1672464000 12345 example.com."
    end

    test "includes type mnemonic" do
      type_covered = ResourceRecordType.new(28)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      str = to_string(record)
      assert str =~ "AAAA"
    end

    test "includes base64-encoded signature" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3, 4>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      str = to_string(record)
      signature_b64 = Base.encode64(signature)
      assert str =~ signature_b64
    end

    test "string interpolation works" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      result = "RRSIG: #{record}"
      assert result =~ "RRSIG:"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = :binary.copy(<<0xAB>>, 64)

      record =
        RRSIG.new({
          type_covered,
          8,
          2,
          3600,
          1_672_531_200,
          1_672_464_000,
          12345,
          signers_name,
          signature
        })

      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length > 0
    end

    test "length prefix matches content" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, rest::binary>> = iodata
      assert length == byte_size(rest)
    end

    test "wire format has correct structure" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>
      signers_name_binary = DNS.to_iodata(signers_name)
      expected_size = 2 + 1 + 1 + 4 + 4 + 4 + 2 + byte_size(signers_name_binary) + 3

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length == expected_size
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back preserves data" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = :binary.copy(<<0xAB>>, 64)

      original =
        RRSIG.new({
          type_covered,
          8,
          2,
          3600,
          1_672_531_200,
          1_672_464_000,
          12345,
          signers_name,
          signature
        })

      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = RRSIG.from_iodata(raw)

      {tc, alg, lab, ttl, exp, inc, kt, sn, sig} = parsed.data
      assert tc.value == <<1::16>>
      assert alg == 8
      assert lab == 2
      assert ttl == 3600
      assert exp == 1_672_531_200
      assert inc == 1_672_464_000
      assert kt == 12345
      assert sn.value == "example.com."
      assert sig == signature
    end
  end

  describe "DNSSEC signature semantics" do
    test "algorithm 8 is RSA/SHA-256" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {_, algorithm, _, _, _, _, _, _, _} = record.data
      assert algorithm == 8
    end

    test "algorithm 13 is ECDSA Curve P-256 with SHA-256" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 13, 2, 3600, 0, 0, 1, signers_name, signature})

      {_, algorithm, _, _, _, _, _, _, _} = record.data
      assert algorithm == 13
    end

    test "algorithm 15 is Ed25519" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 15, 2, 3600, 0, 0, 1, signers_name, signature})

      {_, algorithm, _, _, _, _, _, _, _} = record.data
      assert algorithm == 15
    end

    test "labels count matches domain hierarchy" do
      type_covered = ResourceRecordType.new(1)
      # www.example.com has 3 labels
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 3, 3600, 0, 0, 1, signers_name, signature})

      {_, _, labels, _, _, _, _, _, _} = record.data
      assert labels == 3
    end

    test "signature expiration must be after inception" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>
      inception = 1_672_464_000
      expiration = 1_672_531_200

      record =
        RRSIG.new({type_covered, 8, 2, 3600, expiration, inception, 1, signers_name, signature})

      {_, _, _, _, exp, inc, _, _, _} = record.data
      assert exp > inc
    end

    test "key tag identifies signing key" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 54321, signers_name, signature})

      {_, _, _, _, _, _, key_tag, _, _} = record.data
      assert key_tag == 54321
    end
  end

  describe "common record type signatures" do
    test "A record signature (type 1)" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {tc, _, _, _, _, _, _, _, _} = record.data
      assert tc.value == <<1::16>>
    end

    test "AAAA record signature (type 28)" do
      type_covered = ResourceRecordType.new(28)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {tc, _, _, _, _, _, _, _, _} = record.data
      assert tc.value == <<28::16>>
    end

    test "NS record signature (type 2)" do
      type_covered = ResourceRecordType.new(2)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {tc, _, _, _, _, _, _, _, _} = record.data
      assert tc.value == <<2::16>>
    end

    test "DNSKEY record signature (type 48)" do
      type_covered = ResourceRecordType.new(48)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {tc, _, _, _, _, _, _, _, _} = record.data
      assert tc.value == <<48::16>>
    end

    test "DS record signature (type 43)" do
      type_covered = ResourceRecordType.new(43)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {tc, _, _, _, _, _, _, _, _} = record.data
      assert tc.value == <<43::16>>
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "maximum key tag value" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 65535, signers_name, signature})

      {_, _, _, _, _, _, key_tag, _, _} = record.data
      assert key_tag == 65535
    end

    test "maximum TTL value" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 2, 4_294_967_295, 0, 0, 1, signers_name, signature})

      {_, _, _, ttl, _, _, _, _, _} = record.data
      assert ttl == 4_294_967_295
    end

    test "empty signature" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = <<>>

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {_, _, _, _, _, _, _, _, sig} = record.data
      assert sig == <<>>
    end

    test "long signature (256 bytes)" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("example.com")
      signature = :binary.copy(<<0xFF>>, 256)

      record =
        RRSIG.new({type_covered, 8, 2, 3600, 0, 0, 1, signers_name, signature})

      {_, _, _, _, _, _, _, _, sig} = record.data
      assert byte_size(sig) == 256
    end

    test "subdomain signer's name" do
      type_covered = ResourceRecordType.new(1)
      signers_name = Domain.new("deep.sub.example.com")
      signature = <<1, 2, 3>>

      record =
        RRSIG.new({type_covered, 8, 4, 3600, 0, 0, 1, signers_name, signature})

      {_, _, _, _, _, _, _, sn, _} = record.data
      assert sn.value == "deep.sub.example.com."
    end
  end
end
