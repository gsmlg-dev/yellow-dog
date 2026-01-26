defmodule DNS.Message.Record.Data.HTTPSTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.HTTPS.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with {svc_priority, target_name, svc_params} tuple
  - from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 9460)
  - HTTPS-specific service binding semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.HTTPS
  alias DNS.Message.Domain

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(HTTPS)
    end

    test "exports new/1" do
      Code.ensure_loaded!(HTTPS)
      assert Kernel.function_exported?(HTTPS, :new, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(HTTPS)
      assert Kernel.function_exported?(HTTPS, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(HTTPS)
      assert is_struct(HTTPS.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %HTTPS{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %HTTPS{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %HTTPS{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %HTTPS{}
      assert Map.has_key?(record, :data)
    end

    test "default type is HTTPS (65)" do
      type = %HTTPS{}.type
      assert type == DNS.ResourceRecordType.new(65)
    end

    test "default raw is nil" do
      assert %HTTPS{}.raw == nil
    end

    test "default data is nil" do
      assert %HTTPS{}.data == nil
    end
  end

  describe "new/1" do
    test "creates HTTPS record from 3-element tuple" do
      target = Domain.new("example.com")
      record = HTTPS.new({1, target, <<>>})
      assert %HTTPS{} = record
    end

    test "stores svc_priority field" do
      target = Domain.new("example.com")
      record = HTTPS.new({16, target, <<>>})
      {priority, _, _} = record.data
      assert priority == 16
    end

    test "stores target_name field" do
      target = Domain.new("www.example.com")
      record = HTTPS.new({1, target, <<>>})
      {_, target_name, _} = record.data
      assert target_name == target
    end

    test "stores svc_params field" do
      target = Domain.new("example.com")
      params = <<0, 1, 0, 6, 2, "h3", 2, "h2">>
      record = HTTPS.new({1, target, params})
      {_, _, svc_params} = record.data
      assert svc_params == params
    end

    test "creates AliasMode record (priority=0)" do
      target = Domain.new("www.example.com")
      record = HTTPS.new({0, target, <<>>})
      {priority, _, _} = record.data
      assert priority == 0
    end

    test "creates ServiceMode record (priority>0)" do
      target = Domain.new(".")
      record = HTTPS.new({1, target, <<>>})
      {priority, _, _} = record.data
      assert priority == 1
    end

    test "creates record with root target (.)" do
      target = Domain.new(".")
      record = HTTPS.new({1, target, <<>>})
      {_, target_name, _} = record.data
      assert target_name.value == "."
    end

    test "creates record with empty target" do
      # Empty string normalizes to root "." in DNS
      target = Domain.new("")
      record = HTTPS.new({1, target, <<>>})
      {_, target_name, _} = record.data
      assert target_name.value == "."
    end

    test "creates record with h2 and h3 alpn" do
      target = Domain.new(".")
      # alpn=h3,h2
      alpn_param = <<0, 1, 0, 6, 2, "h3", 2, "h2">>
      record = HTTPS.new({1, target, alpn_param})
      {_, _, params} = record.data
      assert params == alpn_param
    end

    test "creates record with port parameter" do
      target = Domain.new(".")
      # port=8443
      port_param = <<0, 3, 0, 2, 32, 251>>
      record = HTTPS.new({1, target, port_param})
      {_, _, params} = record.data
      assert params == port_param
    end

    test "creates record with ipv4hint parameter" do
      target = Domain.new(".")
      # ipv4hint=93.184.216.34
      ipv4_param = <<0, 4, 0, 4, 93, 184, 216, 34>>
      record = HTTPS.new({1, target, ipv4_param})
      {_, _, params} = record.data
      assert params == ipv4_param
    end

    test "creates record with ipv6hint parameter" do
      target = Domain.new(".")
      # ipv6hint=2606:2800:220:1:248:1893:25c8:1946
      ipv6_param =
        <<0, 6, 0, 16, 0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0x00, 0x01, 0x02, 0x48, 0x18, 0x93,
          0x25, 0xC8, 0x19, 0x46>>

      record = HTTPS.new({1, target, ipv6_param})
      {_, _, params} = record.data
      assert params == ipv6_param
    end

    test "creates record with ech parameter" do
      target = Domain.new(".")
      # ech with some ECH config data
      ech_data = :binary.copy(<<0xAB>>, 32)
      ech_param = <<0, 5, 0, 32, ech_data::binary>>
      record = HTTPS.new({1, target, ech_param})
      {_, _, params} = record.data
      assert params == ech_param
    end

    test "raw field contains binary data" do
      target = Domain.new("example.com")
      record = HTTPS.new({1, target, <<>>})
      assert is_binary(record.raw)
    end

    test "rdlength matches expected size" do
      target = Domain.new("example.com")
      target_binary = DNS.to_iodata(target)
      params = <<0, 1, 0, 3, 2, "h3">>
      record = HTTPS.new({1, target, params})
      expected_size = 2 + byte_size(target_binary) + byte_size(params)
      assert record.rdlength == expected_size
    end
  end

  describe "from_iodata/2" do
    test "parses HTTPS from binary" do
      target = Domain.new("example.com")
      target_binary = DNS.to_iodata(target)
      raw = <<1::16, target_binary::binary>>
      record = HTTPS.from_iodata(raw, nil)
      assert %HTTPS{} = record
    end

    test "parses svc_priority correctly" do
      target = Domain.new("example.com")
      target_binary = DNS.to_iodata(target)
      raw = <<16::16, target_binary::binary>>
      record = HTTPS.from_iodata(raw)
      {priority, _, _} = record.data
      assert priority == 16
    end

    test "parses target_name correctly" do
      target = Domain.new("www.example.com")
      target_binary = DNS.to_iodata(target)
      raw = <<1::16, target_binary::binary>>
      record = HTTPS.from_iodata(raw)
      {_, target_name, _} = record.data
      assert target_name.value == "www.example.com."
    end

    test "parses svc_params correctly" do
      target = Domain.new(".")
      target_binary = DNS.to_iodata(target)
      params = <<0, 1, 0, 6, 2, "h3", 2, "h2">>
      raw = <<1::16, target_binary::binary, params::binary>>
      record = HTTPS.from_iodata(raw)
      {_, _, svc_params} = record.data
      assert svc_params == params
    end

    test "stores raw binary" do
      target = Domain.new("example.com")
      target_binary = DNS.to_iodata(target)
      raw = <<1::16, target_binary::binary>>
      record = HTTPS.from_iodata(raw)
      assert record.raw == raw
    end

    test "parses AliasMode (priority=0)" do
      target = Domain.new("www.example.com")
      target_binary = DNS.to_iodata(target)
      raw = <<0::16, target_binary::binary>>
      record = HTTPS.from_iodata(raw)
      {priority, _, _} = record.data
      assert priority == 0
    end

    test "parses ServiceMode with alpn params" do
      target = Domain.new(".")
      target_binary = DNS.to_iodata(target)
      params = <<0, 1, 0, 6, 2, "h3", 2, "h2">>
      raw = <<1::16, target_binary::binary, params::binary>>
      record = HTTPS.from_iodata(raw)
      {priority, _, svc_params} = record.data
      assert priority == 1
      assert svc_params == params
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats basic HTTPS record" do
      target = Domain.new("example.com")
      record = HTTPS.new({1, target, <<>>})
      str = to_string(record)
      assert str =~ "1"
      assert str =~ "example.com."
    end

    test "formats AliasMode record" do
      target = Domain.new("www.example.com")
      record = HTTPS.new({0, target, <<>>})
      str = to_string(record)
      assert str =~ "0"
      assert str =~ "www.example.com."
    end

    test "string interpolation works" do
      target = Domain.new("secure.example.com")
      record = HTTPS.new({1, target, <<>>})
      result = "HTTPS: #{record}"
      assert result =~ "HTTPS:"
      assert result =~ "secure.example.com."
    end

    test "formats record with alpn h3,h2" do
      target = Domain.new(".")
      params = <<0, 1, 0, 6, 2, "h3", 2, "h2">>
      record = HTTPS.new({1, target, params})
      str = to_string(record)
      assert str =~ "alpn="
      assert str =~ "h3"
      assert str =~ "h2"
    end

    test "formats record without params" do
      target = Domain.new("www.example.com")
      record = HTTPS.new({0, target, <<>>})
      str = to_string(record)
      assert str == "0 www.example.com."
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      target = Domain.new("example.com")
      target_binary = DNS.to_iodata(target)
      record = HTTPS.new({1, target, <<>>})
      iodata = DNS.Parameter.to_iodata(record)
      expected_size = 2 + byte_size(target_binary)
      <<length::16, priority::16, _rest::binary>> = iodata
      assert length == expected_size
      assert priority == 1
    end

    test "length prefix matches rdlength" do
      target = Domain.new("www.example.com")
      params = <<0, 1, 0, 6, 2, "h3", 2, "h2">>
      record = HTTPS.new({1, target, params})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length == record.rdlength
    end

    test "wire format includes svc_params" do
      target = Domain.new(".")
      target_binary = DNS.to_iodata(target)
      params = <<0, 3, 0, 2, 1, 187>>
      record = HTTPS.new({1, target, params})
      iodata = DNS.Parameter.to_iodata(record)
      expected_size = 2 + byte_size(target_binary) + byte_size(params)
      <<length::16, _rest::binary>> = iodata
      assert length == expected_size
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      target = Domain.new("example.com")
      original = HTTPS.new({1, target, <<>>})
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = HTTPS.from_iodata(raw)
      {p1, t1, params1} = original.data
      {p2, t2, params2} = parsed.data
      assert p1 == p2
      assert t1 == t2
      assert params1 == params2
    end

    test "round-trip preserves AliasMode" do
      target = Domain.new("www.example.com")
      original = HTTPS.new({0, target, <<>>})
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = HTTPS.from_iodata(raw)
      {priority, _, _} = parsed.data
      assert priority == 0
    end

    test "round-trip preserves svc_params" do
      target = Domain.new(".")
      params = <<0, 1, 0, 6, 2, "h3", 2, "h2", 0, 3, 0, 2, 1, 187>>
      original = HTTPS.new({1, target, params})
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = HTTPS.from_iodata(raw)
      {_, _, parsed_params} = parsed.data
      assert parsed_params == params
    end
  end

  describe "HTTPS-specific semantics" do
    test "HTTPS record type differs from SVCB" do
      https = %HTTPS{}
      assert https.type == DNS.ResourceRecordType.new(65)
    end

    test "AliasMode for CNAME-like behavior" do
      target = Domain.new("cdn.example.com")
      record = HTTPS.new({0, target, <<>>})
      {priority, _, _} = record.data
      assert priority == 0
    end

    test "ServiceMode for direct HTTPS config" do
      target = Domain.new(".")
      params = <<0, 1, 0, 3, 2, "h3">>
      record = HTTPS.new({1, target, params})
      {priority, _, _} = record.data
      assert priority > 0
    end

    test "h3 alpn for HTTP/3" do
      target = Domain.new(".")
      # alpn=h3
      h3_alpn = <<0, 1, 0, 3, 2, "h3">>
      record = HTTPS.new({1, target, h3_alpn})
      str = to_string(record)
      assert str =~ "h3"
    end

    test "h2 alpn for HTTP/2" do
      target = Domain.new(".")
      # alpn=h2
      h2_alpn = <<0, 1, 0, 3, 2, "h2">>
      record = HTTPS.new({1, target, h2_alpn})
      str = to_string(record)
      assert str =~ "h2"
    end

    test "combined h3 and h2 alpn" do
      target = Domain.new(".")
      # alpn=h3,h2
      combined_alpn = <<0, 1, 0, 6, 2, "h3", 2, "h2">>
      record = HTTPS.new({1, target, combined_alpn})
      str = to_string(record)
      assert str =~ "h3"
      assert str =~ "h2"
    end
  end

  describe "common HTTPS configurations" do
    test "apex to www redirect (AliasMode)" do
      target = Domain.new("www.example.com")
      record = HTTPS.new({0, target, <<>>})
      {priority, target_name, _} = record.data
      assert priority == 0
      assert target_name.value == "www.example.com."
    end

    test "modern HTTPS with HTTP/3" do
      target = Domain.new(".")
      # alpn=h3,h2
      alpn = <<0, 1, 0, 6, 2, "h3", 2, "h2">>
      record = HTTPS.new({1, target, alpn})
      {priority, _, params} = record.data
      assert priority == 1
      assert byte_size(params) > 0
    end

    test "CDN endpoint configuration" do
      target = Domain.new(".")
      # alpn=h3,h2, ipv4hint, ipv6hint
      params = <<
        0,
        1,
        0,
        6,
        2,
        "h3",
        2,
        "h2",
        0,
        4,
        0,
        4,
        192,
        168,
        1,
        1,
        0,
        6,
        0,
        16,
        0x20,
        0x01,
        0x0D,
        0xB8,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1
      >>

      record = HTTPS.new({1, target, params})
      {priority, _, svc_params} = record.data
      assert priority == 1
      assert byte_size(svc_params) > 20
    end

    test "alternate port for HTTPS" do
      target = Domain.new(".")
      # port=8443
      port_param = <<0, 3, 0, 2, 32, 251>>
      record = HTTPS.new({1, target, port_param})
      {_, _, params} = record.data
      <<key::16, len::16, port::16>> = params
      assert key == 3
      assert len == 2
      assert port == 8443
    end
  end

  describe "SvcParams for HTTPS" do
    test "alpn parameter (key=1)" do
      target = Domain.new(".")
      alpn = <<0, 1, 0, 3, 2, "h3">>
      record = HTTPS.new({1, target, alpn})
      {_, _, params} = record.data
      <<key::16, _rest::binary>> = params
      assert key == 1
    end

    test "no-default-alpn parameter (key=2)" do
      target = Domain.new(".")
      no_default = <<0, 2, 0, 0>>
      record = HTTPS.new({1, target, no_default})
      {_, _, params} = record.data
      <<key::16, _rest::binary>> = params
      assert key == 2
    end

    test "port parameter (key=3)" do
      target = Domain.new(".")
      port = <<0, 3, 0, 2, 1, 187>>
      record = HTTPS.new({1, target, port})
      {_, _, params} = record.data
      <<key::16, _rest::binary>> = params
      assert key == 3
    end

    test "ipv4hint parameter (key=4)" do
      target = Domain.new(".")
      ipv4 = <<0, 4, 0, 4, 192, 168, 1, 1>>
      record = HTTPS.new({1, target, ipv4})
      {_, _, params} = record.data
      <<key::16, _rest::binary>> = params
      assert key == 4
    end

    test "ech parameter (key=5)" do
      target = Domain.new(".")
      ech_config = :binary.copy(<<0xAB>>, 32)
      ech = <<0, 5, 0, 32, ech_config::binary>>
      record = HTTPS.new({1, target, ech})
      {_, _, params} = record.data
      <<key::16, _rest::binary>> = params
      assert key == 5
    end

    test "ipv6hint parameter (key=6)" do
      target = Domain.new(".")
      ipv6 = <<0, 6, 0, 16, 0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = HTTPS.new({1, target, ipv6})
      {_, _, params} = record.data
      <<key::16, _rest::binary>> = params
      assert key == 6
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      target = Domain.new("example.com")
      record = HTTPS.new({1, target, <<>>})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "max priority (65535)" do
      target = Domain.new(".")
      record = HTTPS.new({65535, target, <<>>})
      {priority, _, _} = record.data
      assert priority == 65535
    end

    test "deeply nested subdomain" do
      target = Domain.new("a.b.c.d.e.f.example.com")
      record = HTTPS.new({1, target, <<>>})
      {_, target_name, _} = record.data
      assert target_name.value == "a.b.c.d.e.f.example.com."
    end

    test "empty svc_params" do
      target = Domain.new("example.com")
      record = HTTPS.new({1, target, <<>>})
      {_, _, params} = record.data
      assert params == <<>>
    end

    test "large svc_params with multiple params" do
      target = Domain.new(".")
      # Multiple params
      large_params = <<
        0,
        1,
        0,
        6,
        2,
        "h3",
        2,
        "h2",
        0,
        3,
        0,
        2,
        1,
        187,
        0,
        4,
        0,
        8,
        192,
        168,
        1,
        1,
        192,
        168,
        1,
        2,
        0,
        6,
        0,
        32,
        0x20,
        0x01,
        0x0D,
        0xB8,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        0x20,
        0x01,
        0x0D,
        0xB8,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        2
      >>

      record = HTTPS.new({1, target, large_params})
      {_, _, params} = record.data
      assert byte_size(params) > 50
    end
  end
end
