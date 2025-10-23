defmodule DNS.Message.Record.Data.RRSIGTest do
  use ExUnit.Case
  alias DNS.Message.Record.Data.RRSIG

  describe "new/1" do
    test "creates RRSIG record with valid parameters" do
      # A record
      type_covered = DNS.ResourceRecordType.new(1)
      # RSA/SHA-256
      algorithm = 8
      labels = 2
      original_ttl = 3600
      # 2023-01-01 00:00:00 UTC
      signature_expiration = 1_672_531_200
      # 2022-12-31 00:00:00 UTC
      signature_inception = 1_672_464_000
      key_tag = 12345
      signers_name = DNS.Message.Domain.new("example.com")
      signature = :binary.copy(<<0xAB>>, 64)

      rrsig =
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

      assert rrsig.type.value == <<46::16>>

      assert rrsig.data == {
               type_covered,
               algorithm,
               labels,
               original_ttl,
               signature_expiration,
               signature_inception,
               key_tag,
               signers_name,
               signature
             }
    end

    test "handles minimal RRSIG record" do
      type_covered = DNS.ResourceRecordType.new(255)
      algorithm = 1
      labels = 0
      original_ttl = 0
      signature_expiration = 0
      signature_inception = 0
      key_tag = 0
      signers_name = DNS.Message.Domain.new("")
      signature = <<>>

      rrsig =
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

      assert rrsig.type.value == <<46::16>>

      assert rrsig.data == {
               type_covered,
               algorithm,
               labels,
               original_ttl,
               signature_expiration,
               signature_inception,
               key_tag,
               signers_name,
               signature
             }
    end
  end

  describe "from_iodata/2" do
    test "parses RRSIG record correctly" do
      type_covered = 1
      algorithm = 8
      labels = 2
      original_ttl = 3600
      signature_expiration = 1_672_531_200
      signature_inception = 1_672_464_000
      key_tag = 12345
      signers_name = DNS.Message.Domain.new("example.com")
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

      rrsig = RRSIG.from_iodata(raw)

      assert rrsig.type.value == <<46::16>>
      assert elem(rrsig.data, 0).value == <<type_covered::16>>
      assert elem(rrsig.data, 1) == algorithm
      assert elem(rrsig.data, 2) == labels
      assert elem(rrsig.data, 3) == original_ttl
      assert elem(rrsig.data, 4) == signature_expiration
      assert elem(rrsig.data, 5) == signature_inception
      assert elem(rrsig.data, 6) == key_tag
      assert to_string(elem(rrsig.data, 7)) == "example.com."
      assert elem(rrsig.data, 8) == signature
    end

    test "parses short RRSIG record" do
      type_covered = 1
      algorithm = 1
      labels = 0
      original_ttl = 300
      signature_expiration = 1_672_531_200
      signature_inception = 1_672_464_000
      key_tag = 1
      signers_name = DNS.Message.Domain.new("a")
      signature = <<0xCD, 0xEF>>

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

      rrsig = RRSIG.from_iodata(raw)

      assert rrsig.type.value == <<46::16>>
      assert elem(rrsig.data, 0).value == <<type_covered::16>>
      assert elem(rrsig.data, 1) == algorithm
      assert elem(rrsig.data, 2) == labels
      assert elem(rrsig.data, 3) == original_ttl
      assert elem(rrsig.data, 4) == signature_expiration
      assert elem(rrsig.data, 5) == signature_inception
      assert elem(rrsig.data, 6) == key_tag
      assert to_string(elem(rrsig.data, 7)) == "a."
      assert elem(rrsig.data, 8) == signature
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts RRSIG record to iodata" do
      type_covered = DNS.ResourceRecordType.new(1)
      algorithm = 8
      labels = 2
      original_ttl = 3600
      signature_expiration = 1_672_531_200
      signature_inception = 1_672_464_000
      key_tag = 12345
      signers_name = DNS.Message.Domain.new("example.com")
      signature = :binary.copy(<<0xAB>>, 64)

      rrsig =
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

      iodata = DNS.Parameter.to_iodata(rrsig)
      signers_name_binary = DNS.to_iodata(signers_name)

      expected_size =
        2 + 1 + 1 + 4 + 4 + 4 + 2 + byte_size(signers_name_binary) + byte_size(signature)

      expected =
        <<expected_size::16, type_covered.value::binary, algorithm::8, labels::8,
          original_ttl::32, signature_expiration::32, signature_inception::32, key_tag::16,
          signers_name_binary::binary, signature::binary>>

      assert iodata == expected
    end
  end

  describe "String.Chars protocol" do
    test "converts RRSIG record to string" do
      type_covered = DNS.ResourceRecordType.new(1)
      algorithm = 8
      labels = 2
      original_ttl = 3600
      signature_expiration = 1_672_531_200
      signature_inception = 1_672_464_000
      key_tag = 12345
      signers_name = DNS.Message.Domain.new("example.com")
      signature = :binary.copy(<<0xAB>>, 64)

      rrsig =
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

      str = to_string(rrsig)

      assert str =~ "A 8 2 3600 1672531200 1672464000 12345 example.com."
    end
  end
end
