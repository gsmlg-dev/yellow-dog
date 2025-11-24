defmodule DNS.Message.Record.Data.TLSATest do
  use ExUnit.Case
  alias DNS.Message.Record.Data.TLSA

  describe "new/1" do
    test "creates TLSA record with valid parameters" do
      # Domain-issued certificate
      usage = 3
      # SubjectPublicKeyInfo
      selector = 1
      # SHA-256
      matching_type = 1
      # SHA-256 hash
      cert_data = :binary.copy(<<0x01, 0x02, 0x03, 0x04>>, 32)

      tlsa = TLSA.new({usage, selector, matching_type, cert_data})

      assert tlsa.type.value == <<52::16>>
      assert tlsa.data == {usage, selector, matching_type, cert_data}

      expected_raw = <<usage::8, selector::8, matching_type::8, cert_data::binary>>
      assert tlsa.raw == expected_raw
      assert tlsa.rdlength == 3 + byte_size(cert_data)
    end

    test "creates TLSA record with different parameters" do
      # CA constraint
      usage = 0
      # Full certificate
      selector = 0
      # Exact match
      matching_type = 0
      # Full certificate
      cert_data = :binary.copy(<<0xAA, 0xBB>>, 64)

      tlsa = TLSA.new({usage, selector, matching_type, cert_data})

      assert tlsa.data == {usage, selector, matching_type, cert_data}
      assert tlsa.rdlength == 3 + 128
    end

    test "handles TLSA record with SHA-512" do
      # Trust anchor constraint
      usage = 2
      # SubjectPublicKeyInfo
      selector = 1
      # SHA-512
      matching_type = 2
      # SHA-512 truncated
      cert_data = :binary.copy(<<0x11, 0x22>>, 32)

      tlsa = TLSA.new({usage, selector, matching_type, cert_data})

      assert tlsa.data == {usage, selector, matching_type, cert_data}
      assert tlsa.rdlength == 3 + 64
    end

    test "handles minimal TLSA record" do
      usage = 0
      selector = 0
      matching_type = 0
      cert_data = <<>>

      tlsa = TLSA.new({usage, selector, matching_type, cert_data})

      assert tlsa.type.value == <<52::16>>
      assert tlsa.data == {usage, selector, matching_type, cert_data}
      assert tlsa.rdlength == 3
    end
  end

  describe "from_iodata/2" do
    test "parses TLSA record correctly" do
      usage = 3
      selector = 1
      matching_type = 1
      cert_data = :binary.copy(<<0x01, 0x02, 0x03, 0x04>>, 32)
      raw = <<usage::8, selector::8, matching_type::8, cert_data::binary>>

      tlsa = TLSA.from_iodata(raw)

      assert tlsa.type.value == <<52::16>>
      assert tlsa.data == {usage, selector, matching_type, cert_data}
      assert tlsa.raw == raw
    end

    test "parses TLSA record with different parameters" do
      # Service certificate constraint
      usage = 1
      # Full certificate
      selector = 0
      # SHA-512
      matching_type = 2
      cert_data = <<0xAA, 0xBB, 0xCC, 0xDD>>
      raw = <<usage::8, selector::8, matching_type::8, cert_data::binary>>

      tlsa = TLSA.from_iodata(raw)

      assert tlsa.rdlength == 7
      assert tlsa.data == {usage, selector, matching_type, cert_data}
    end

    test "parses TLSA record with empty certificate data" do
      usage = 0
      selector = 0
      matching_type = 0
      cert_data = <<>>
      raw = <<usage::8, selector::8, matching_type::8, cert_data::binary>>

      tlsa = TLSA.from_iodata(raw)

      assert tlsa.rdlength == 3
      assert tlsa.data == {usage, selector, matching_type, cert_data}
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts TLSA record to iodata" do
      usage = 3
      selector = 1
      matching_type = 1
      cert_data = :binary.copy(<<0x01, 0x02, 0x03, 0x04>>, 32)
      tlsa = TLSA.new({usage, selector, matching_type, cert_data})

      iodata = DNS.Parameter.to_iodata(tlsa)
      expected_size = 3 + byte_size(cert_data)
      expected = <<expected_size::16, usage::8, selector::8, matching_type::8, cert_data::binary>>

      assert iodata == expected
    end

    test "converts minimal TLSA record to iodata" do
      usage = 0
      selector = 0
      matching_type = 0
      cert_data = <<>>
      tlsa = TLSA.new({usage, selector, matching_type, cert_data})

      iodata = DNS.Parameter.to_iodata(tlsa)
      expected = <<3::16, usage::8, selector::8, matching_type::8>>

      assert iodata == expected
    end
  end

  describe "String.Chars protocol" do
    test "converts TLSA record to string" do
      usage = 3
      selector = 1
      matching_type = 1
      cert_data = :binary.copy(<<0x01, 0x02, 0x03, 0x04>>, 32)
      tlsa = TLSA.new({usage, selector, matching_type, cert_data})

      str = to_string(tlsa)
      cert_hex = Base.encode16(cert_data, case: :lower)

      assert str == "#{usage} #{selector} #{matching_type} #{cert_hex}"
    end

    test "converts TLSA record with empty data to string" do
      usage = 0
      selector = 0
      matching_type = 0
      cert_data = <<>>
      tlsa = TLSA.new({usage, selector, matching_type, cert_data})

      str = to_string(tlsa)

      assert str == "#{usage} #{selector} #{matching_type} "
    end
  end
end
