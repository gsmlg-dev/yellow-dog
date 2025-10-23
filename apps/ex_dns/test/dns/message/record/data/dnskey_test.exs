defmodule DNS.Message.Record.Data.DNSKEYTest do
  use ExUnit.Case
  alias DNS.Message.Record.Data.DNSKEY

  describe "new/1" do
    test "creates DNSKEY record with valid parameters" do
      # Zone Key
      flags = 257
      # DNSSEC
      protocol = 3
      # RSA/SHA-256
      algorithm = 8
      public_key = :binary.copy(<<0x01, 0x02, 0x03, 0x04>>, 64)

      dnskey = DNSKEY.new({flags, protocol, algorithm, public_key})

      assert dnskey.type.value == <<48::16>>
      assert dnskey.data == {flags, protocol, algorithm, public_key}

      expected_raw = <<flags::16, protocol::8, algorithm::8, public_key::binary>>
      assert dnskey.raw == expected_raw
      assert dnskey.rdlength == 2 + 1 + 1 + byte_size(public_key)
    end

    test "creates DNSKEY record with SEP flag" do
      # Zone Key + Secure Entry Point
      flags = 257
      protocol = 3
      algorithm = 8
      public_key = <<0x01, 0x02, 0x03, 0x04>>

      dnskey = DNSKEY.new({flags, protocol, algorithm, public_key})

      assert dnskey.data == {flags, protocol, algorithm, public_key}
    end

    test "creates DNSKEY record with Revoke flag" do
      # Revoke
      flags = 128
      protocol = 3
      algorithm = 8
      public_key = <<0x01, 0x02, 0x03>>

      dnskey = DNSKEY.new({flags, protocol, algorithm, public_key})

      assert dnskey.data == {flags, protocol, algorithm, public_key}
    end

    test "handles minimal DNSKEY record" do
      flags = 0
      protocol = 0
      algorithm = 0
      public_key = <<>>

      dnskey = DNSKEY.new({flags, protocol, algorithm, public_key})

      assert dnskey.type.value == <<48::16>>
      assert dnskey.data == {flags, protocol, algorithm, public_key}
      assert dnskey.rdlength == 4
    end
  end

  describe "from_iodata/2" do
    test "parses DNSKEY record correctly" do
      flags = 257
      protocol = 3
      algorithm = 8
      public_key = :binary.copy(<<0x01, 0x02, 0x03, 0x04>>, 64)
      raw = <<flags::16, protocol::8, algorithm::8, public_key::binary>>

      dnskey = DNSKEY.from_iodata(raw)

      assert dnskey.type.value == <<48::16>>
      assert dnskey.data == {flags, protocol, algorithm, public_key}
      assert dnskey.raw == raw
    end

    test "parses short DNSKEY record" do
      flags = 256
      protocol = 3
      algorithm = 5
      public_key = <<0xAA, 0xBB, 0xCC>>
      raw = <<flags::16, protocol::8, algorithm::8, public_key::binary>>

      dnskey = DNSKEY.from_iodata(raw)

      assert dnskey.rdlength == 7
      assert dnskey.data == {flags, protocol, algorithm, public_key}
    end

    test "parses DNSKEY with different flags" do
      # Zone Key + SEP
      flags = 0x0101
      protocol = 3
      # RSA/SHA-512
      algorithm = 10
      public_key = <<0x01>>
      raw = <<flags::16, protocol::8, algorithm::8, public_key::binary>>

      dnskey = DNSKEY.from_iodata(raw)

      assert dnskey.data == {flags, protocol, algorithm, public_key}
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts DNSKEY record to iodata" do
      flags = 257
      protocol = 3
      algorithm = 8
      public_key = :binary.copy(<<0x01, 0x02, 0x03, 0x04>>, 64)
      dnskey = DNSKEY.new({flags, protocol, algorithm, public_key})

      iodata = DNS.Parameter.to_iodata(dnskey)
      expected_size = 2 + 1 + 1 + byte_size(public_key)
      expected = <<expected_size::16, flags::16, protocol::8, algorithm::8, public_key::binary>>

      assert iodata == expected
    end

    test "converts minimal DNSKEY record to iodata" do
      flags = 0
      protocol = 0
      algorithm = 0
      public_key = <<>>
      dnskey = DNSKEY.new({flags, protocol, algorithm, public_key})

      iodata = DNS.Parameter.to_iodata(dnskey)
      expected = <<4::16, flags::16, protocol::8, algorithm::8>>

      assert iodata == expected
    end
  end

  describe "String.Chars protocol" do
    test "converts DNSKEY record to string" do
      flags = 257
      protocol = 3
      algorithm = 8
      public_key = :binary.copy(<<0x01, 0x02, 0x03, 0x04>>, 64)
      dnskey = DNSKEY.new({flags, protocol, algorithm, public_key})

      str = to_string(dnskey)
      public_key_b64 = Base.encode64(public_key)

      assert str == "#{flags} #{protocol} #{algorithm} #{public_key_b64}"
    end

    test "converts minimal DNSKEY record to string" do
      flags = 0
      protocol = 0
      algorithm = 0
      public_key = <<>>
      dnskey = DNSKEY.new({flags, protocol, algorithm, public_key})

      str = to_string(dnskey)
      public_key_b64 = Base.encode64(public_key)

      assert str == "#{flags} #{protocol} #{algorithm} #{public_key_b64}"
    end
  end
end
