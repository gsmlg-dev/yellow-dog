defmodule DNS.Message.Record.Data.SVCBTest do
  use ExUnit.Case
  alias DNS.Message.Record.Data.SVCB
  alias DNS.Message.Domain

  describe "new/1" do
    test "creates SVCB record with valid parameters" do
      svc_priority = 1
      target_name = Domain.new("example.com")
      # alpn="h2"
      svc_params = <<0x00, 0x01, 0x00, 0x04, 192, 168, 1, 1>>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      assert svcb.type.value == <<64::16>>
      assert svcb.data == {svc_priority, target_name, svc_params}

      target_name_binary = DNS.to_iodata(target_name)

      expected_raw = <<
        svc_priority::16,
        target_name_binary::binary,
        svc_params::binary
      >>

      assert svcb.raw == expected_raw
      assert svcb.rdlength == 2 + byte_size(target_name_binary) + byte_size(svc_params)
    end

    test "creates SVCB record with AliasMode" do
      # AliasMode
      svc_priority = 0
      target_name = Domain.new("target.example.com")
      # Empty for AliasMode
      svc_params = <<>>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      assert svcb.data == {svc_priority, target_name, svc_params}
    end

    test "creates SVCB record with ServiceMode" do
      # ServiceMode
      svc_priority = 16
      # Root (no alternative)
      target_name = Domain.new(".")
      svc_params = <<0x00, 0x01, 0x00, 0x04, 192, 168, 1, 1>>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      assert svcb.data == {svc_priority, target_name, svc_params}
    end

    test "handles SVCB record with complex parameters" do
      svc_priority = 1
      target_name = Domain.new("svc.example.net")

      svc_params = <<
        # alpn="https"
        0x00,
        0x01,
        0x00,
        0x05,
        104,
        116,
        116,
        112,
        115,
        # ipv4hint
        0x00,
        0x03,
        0x00,
        0x04,
        192,
        168,
        1,
        100,
        # ipv6hint
        0x00,
        0x04,
        0x00,
        0x10,
        0x20,
        0x01,
        0x0D,
        0xB8,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01
      >>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      assert svcb.data == {svc_priority, target_name, svc_params}
    end

    test "handles minimal SVCB record" do
      svc_priority = 1
      target_name = Domain.new("")
      svc_params = <<>>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      assert svcb.type.value == <<64::16>>
      assert svcb.data == {svc_priority, target_name, svc_params}
    end
  end

  describe "from_iodata/2" do
    test "parses SVCB record correctly" do
      svc_priority = 1
      target_name = Domain.new("example.com")
      # alpn="http"
      svc_params = <<0x00, 0x01, 0x00, 0x04, 104, 116, 116, 112>>

      target_name_binary = DNS.to_iodata(target_name)

      raw = <<
        svc_priority::16,
        target_name_binary::binary,
        svc_params::binary
      >>

      svcb = SVCB.from_iodata(raw)

      assert svcb.type.value == <<64::16>>
      assert svcb.data == {svc_priority, target_name, svc_params}
      assert svcb.raw == raw
    end

    test "parses SVCB record in AliasMode" do
      svc_priority = 0
      target_name = Domain.new("target.example.com")
      svc_params = <<>>

      target_name_binary = DNS.to_iodata(target_name)

      raw = <<
        svc_priority::16,
        target_name_binary::binary
      >>

      svcb = SVCB.from_iodata(raw)

      assert svcb.data == {svc_priority, target_name, svc_params}
    end

    test "parses SVCB record with root target" do
      svc_priority = 16
      target_name = Domain.new(".")
      svc_params = <<0x00, 0x01, 0x00, 0x05, 104, 116, 116, 112, 115>>

      target_name_binary = DNS.to_iodata(target_name)

      raw = <<
        svc_priority::16,
        target_name_binary::binary,
        svc_params::binary
      >>

      svcb = SVCB.from_iodata(raw)

      assert svcb.data == {svc_priority, target_name, svc_params}
    end

    test "parses SVCB record with minimal data" do
      svc_priority = 1
      target_name = Domain.new("")
      svc_params = <<>>

      target_name_binary = DNS.to_iodata(target_name)

      raw = <<
        svc_priority::16,
        target_name_binary::binary
      >>

      svcb = SVCB.from_iodata(raw)

      assert svcb.data == {svc_priority, target_name, svc_params}
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts SVCB record to iodata" do
      svc_priority = 1
      target_name = Domain.new("example.com")
      svc_params = <<0x00, 0x01, 0x00, 0x04, 104, 116, 116, 112>>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      iodata = DNS.Parameter.to_iodata(svcb)
      target_name_binary = DNS.to_iodata(target_name)
      expected_size = 2 + byte_size(target_name_binary) + byte_size(svc_params)

      expected =
        <<expected_size::16, svc_priority::16, target_name_binary::binary, svc_params::binary>>

      assert iodata == expected
    end

    test "converts AliasMode SVCB to iodata" do
      svc_priority = 0
      target_name = Domain.new("target.example.com")
      svc_params = <<>>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      iodata = DNS.Parameter.to_iodata(svcb)
      target_name_binary = DNS.to_iodata(target_name)
      expected_size = 2 + byte_size(target_name_binary)

      expected = <<expected_size::16, svc_priority::16, target_name_binary::binary>>

      assert iodata == expected
    end

    test "converts minimal SVCB record to iodata" do
      svc_priority = 1
      target_name = Domain.new("")
      svc_params = <<>>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      iodata = DNS.Parameter.to_iodata(svcb)
      target_name_binary = DNS.to_iodata(target_name)
      expected_size = 2 + byte_size(target_name_binary)

      expected = <<expected_size::16, svc_priority::16, target_name_binary::binary>>

      assert iodata == expected
    end
  end

  describe "String.Chars protocol" do
    test "converts SVCB record to string" do
      svc_priority = 1
      target_name = Domain.new("example.com")
      svc_params = <<0x00, 0x01, 0x00, 0x05, 4, 104, 116, 116, 112>>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      str = to_string(svcb)

      assert str == "#{svc_priority} #{target_name} alpn=http"
    end

    test "converts AliasMode SVCB to string" do
      svc_priority = 0
      target_name = Domain.new("target.example.com")
      svc_params = <<>>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      str = to_string(svcb)

      assert str == "#{svc_priority} #{target_name} #{svc_params}"
    end

    test "converts SVCB with root target to string" do
      svc_priority = 16
      target_name = Domain.new(".")
      svc_params = <<0x00, 0x01, 0x00, 0x06, 5, 104, 116, 116, 112, 115>>

      svcb = SVCB.new({svc_priority, target_name, svc_params})

      str = to_string(svcb)

      assert str == "#{svc_priority} #{target_name} alpn=https"
    end
  end
end
