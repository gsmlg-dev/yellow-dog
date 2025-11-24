defmodule DNS.Message.Record.Data.HTTPSTest do
  use ExUnit.Case
  alias DNS.Message.Record.Data.HTTPS
  alias DNS.Message.Domain

  describe "new/1" do
    test "creates HTTPS record with valid parameters" do
      svc_priority = 1
      target_name = Domain.new("example.com")
      # alpn="http"
      svc_params = <<0, 1, 0, 4, 104, 116, 116, 112>>

      https = HTTPS.new({svc_priority, target_name, svc_params})

      assert https.type.value == <<65::16>>
      assert https.data == {svc_priority, target_name, svc_params}

      target_name_binary = DNS.to_iodata(target_name)

      expected_raw = <<
        svc_priority::16,
        target_name_binary::binary,
        svc_params::binary
      >>

      assert https.raw == expected_raw
      assert https.rdlength == 2 + byte_size(target_name_binary) + byte_size(svc_params)
    end

    test "creates HTTPS record with AliasMode" do
      # AliasMode
      svc_priority = 0
      target_name = Domain.new("target.example.com")
      # Empty for AliasMode
      svc_params = <<>>

      https = HTTPS.new({svc_priority, target_name, svc_params})

      assert https.data == {svc_priority, target_name, svc_params}
    end

    test "creates HTTPS record with ServiceMode" do
      # ServiceMode
      svc_priority = 16
      # Root (no alternative)
      target_name = Domain.new(".")
      # alpn="https"
      svc_params = <<0, 1, 0, 6, 2, 104, 51, 2, 104, 50>>

      https = HTTPS.new({svc_priority, target_name, svc_params})

      assert https.data == {svc_priority, target_name, svc_params}
    end

    test "handles HTTPS record with complex parameters" do
      svc_priority = 1
      target_name = Domain.new("svc.example.net")

      svc_params = <<
        # alpn="https"
        0,
        1,
        0,
        5,
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

      https = HTTPS.new({svc_priority, target_name, svc_params})

      assert https.data == {svc_priority, target_name, svc_params}
    end

    test "handles minimal HTTPS record" do
      svc_priority = 1
      target_name = Domain.new("")
      svc_params = <<>>

      https = HTTPS.new({svc_priority, target_name, svc_params})

      assert https.type.value == <<65::16>>
      assert https.data == {svc_priority, target_name, svc_params}
    end
  end

  describe "from_iodata/2" do
    test "parses HTTPS record correctly" do
      svc_priority = 1
      target_name = Domain.new("example.com")
      # alpn="https"
      svc_params = <<0, 1, 0, 6, 2, 104, 51, 2, 104, 50>>

      target_name_binary = DNS.to_iodata(target_name)

      raw = <<
        svc_priority::16,
        target_name_binary::binary,
        svc_params::binary
      >>

      https = HTTPS.from_iodata(raw)

      assert https.type.value == <<65::16>>
      assert https.data == {svc_priority, target_name, svc_params}
      assert https.raw == raw
    end

    test "parses HTTPS record in AliasMode" do
      svc_priority = 0
      target_name = Domain.new("target.example.com")
      svc_params = <<>>

      target_name_binary = DNS.to_iodata(target_name)

      raw = <<
        svc_priority::16,
        target_name_binary::binary
      >>

      https = HTTPS.from_iodata(raw)

      assert https.data == {svc_priority, target_name, svc_params}
    end

    test "parses HTTPS record with root target" do
      svc_priority = 16
      target_name = Domain.new(".")
      svc_params = <<0, 1, 0, 6, 2, 104, 51, 2, 104, 50>>

      target_name_binary = DNS.to_iodata(target_name)

      raw = <<
        svc_priority::16,
        target_name_binary::binary,
        svc_params::binary
      >>

      https = HTTPS.from_iodata(raw)

      assert https.data == {svc_priority, target_name, svc_params}
    end

    test "parses HTTPS record with minimal data" do
      svc_priority = 1
      target_name = Domain.new("")
      svc_params = <<>>

      target_name_binary = DNS.to_iodata(target_name)

      raw = <<
        svc_priority::16,
        target_name_binary::binary
      >>

      https = HTTPS.from_iodata(raw)

      assert https.data == {svc_priority, target_name, svc_params}
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts HTTPS record to iodata" do
      svc_priority = 1
      target_name = Domain.new("example.com")
      svc_params = <<0x00, 0x01, 0x00, 0x05, 104, 116, 116, 112, 115>>

      https = HTTPS.new({svc_priority, target_name, svc_params})

      iodata = DNS.Parameter.to_iodata(https)
      target_name_binary = DNS.to_iodata(target_name)
      expected_size = 2 + byte_size(target_name_binary) + byte_size(svc_params)

      expected =
        <<expected_size::16, svc_priority::16, target_name_binary::binary, svc_params::binary>>

      assert iodata == expected
    end

    test "converts AliasMode HTTPS to iodata" do
      svc_priority = 0
      target_name = Domain.new("target.example.com")
      svc_params = <<>>

      https = HTTPS.new({svc_priority, target_name, svc_params})

      iodata = DNS.Parameter.to_iodata(https)
      target_name_binary = DNS.to_iodata(target_name)
      expected_size = 2 + byte_size(target_name_binary)

      expected = <<expected_size::16, svc_priority::16, target_name_binary::binary>>

      assert iodata == expected
    end

    test "converts minimal HTTPS record to iodata" do
      svc_priority = 1
      target_name = Domain.new("")
      svc_params = <<>>

      https = HTTPS.new({svc_priority, target_name, svc_params})

      iodata = DNS.Parameter.to_iodata(https)
      target_name_binary = DNS.to_iodata(target_name)
      expected_size = 2 + byte_size(target_name_binary)

      expected = <<expected_size::16, svc_priority::16, target_name_binary::binary>>

      assert iodata == expected
    end
  end

  describe "String.Chars protocol" do
    test "converts HTTPS record to string" do
      svc_priority = 1
      target_name = Domain.new("example.com")
      svc_params = <<0, 1, 0, 6, 2, 104, 51, 2, 104, 50>>

      https = HTTPS.new({svc_priority, target_name, svc_params})

      str = to_string(https)

      assert str == "#{svc_priority} #{target_name} alpn=h3,h2"
    end

    test "converts AliasMode HTTPS to string" do
      svc_priority = 0
      target_name = Domain.new("target.example.com")
      svc_params = <<>>

      https = HTTPS.new({svc_priority, target_name, svc_params})

      str = to_string(https)

      assert str == "#{svc_priority} #{target_name}"
    end

    test "converts HTTPS with root target to string" do
      svc_priority = 16
      target_name = Domain.new(".")
      svc_params = <<0, 1, 0, 6, 2, 104, 51, 2, 104, 50>>

      https = HTTPS.new({svc_priority, target_name, svc_params})

      str = to_string(https)

      assert str == "#{svc_priority} #{target_name} alpn=h3,h2"
    end
  end

  # test "parse message" do
  #   message = DNS.Message.from_iodata(@message)
  #   [r1, r2] = message.anlist
  #   assert r1.type == DNS.ResourceRecordType.new(46)
  #   assert r2.type == DNS.ResourceRecordType.new(65)
  #   IO.puts(r2)
  #   IO.puts(message.header)
  #   for q <- message.qdlist, do: IO.puts(q)
  #   for an <- message.anlist, do: IO.puts(an)
  #   for ns <- message.nslist, do: IO.puts(ns)
  #   for ar <- message.arlist, do: IO.puts(ar)
  # end
end
