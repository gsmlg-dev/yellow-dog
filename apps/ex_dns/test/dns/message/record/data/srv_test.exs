defmodule DNS.Message.Record.Data.SRVTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.SRV.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with {priority, weight, port, target} tuple
  - from_iodata/1, from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 2782)
  - Service location and load balancing semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.SRV
  alias DNS.Message.Domain

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(SRV)
    end

    test "exports new/1" do
      Code.ensure_loaded!(SRV)
      assert Kernel.function_exported?(SRV, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(SRV)
      assert Kernel.function_exported?(SRV, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(SRV)
      assert Kernel.function_exported?(SRV, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(SRV)
      assert is_struct(SRV.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %SRV{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %SRV{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %SRV{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %SRV{}
      assert Map.has_key?(record, :data)
    end

    test "default type is SRV (33)" do
      type = %SRV{}.type
      assert type == DNS.ResourceRecordType.new(33)
    end

    test "default raw is nil" do
      assert %SRV{}.raw == nil
    end

    test "default data is nil" do
      assert %SRV{}.data == nil
    end
  end

  describe "new/1" do
    test "creates SRV record from 4-element tuple" do
      record = SRV.new({10, 20, 443, "server.example.com"})
      assert %SRV{} = record
      assert {10, 20, 443, %Domain{}} = record.data
    end

    test "stores priority" do
      record = SRV.new({10, 0, 80, "web.example.com"})
      {priority, _, _, _} = record.data
      assert priority == 10
    end

    test "stores weight" do
      record = SRV.new({0, 50, 80, "web.example.com"})
      {_, weight, _, _} = record.data
      assert weight == 50
    end

    test "stores port" do
      record = SRV.new({0, 0, 8080, "api.example.com"})
      {_, _, port, _} = record.data
      assert port == 8080
    end

    test "stores target domain" do
      record = SRV.new({0, 0, 443, "secure.example.com"})
      {_, _, _, domain} = record.data
      assert domain == Domain.new("secure.example.com")
    end

    test "creates record with priority 0 (highest)" do
      record = SRV.new({0, 10, 80, "primary.example.com"})
      {priority, _, _, _} = record.data
      assert priority == 0
    end

    test "creates record with max priority (65535)" do
      record = SRV.new({65535, 10, 80, "backup.example.com"})
      {priority, _, _, _} = record.data
      assert priority == 65535
    end

    test "creates record with weight 0 (no load balancing)" do
      record = SRV.new({10, 0, 80, "single.example.com"})
      {_, weight, _, _} = record.data
      assert weight == 0
    end

    test "creates record with high weight" do
      record = SRV.new({10, 100, 80, "heavy.example.com"})
      {_, weight, _, _} = record.data
      assert weight == 100
    end

    test "creates record for HTTPS service" do
      record = SRV.new({10, 50, 443, "www.example.com"})
      {_, _, port, _} = record.data
      assert port == 443
    end

    test "creates record for LDAP service" do
      record = SRV.new({0, 0, 389, "ldap.example.com"})
      {_, _, port, _} = record.data
      assert port == 389
    end

    test "raw field contains binary data" do
      record = SRV.new({10, 20, 80, "web.example.com"})
      assert is_binary(record.raw)
    end

    test "rdlength is domain size plus 6 bytes" do
      domain = Domain.new("web.example.com")
      record = SRV.new({10, 20, 80, "web.example.com"})
      assert record.rdlength == domain.size + 6
    end
  end

  describe "from_iodata/1" do
    test "parses SRV from binary" do
      domain_raw = DNS.to_iodata(Domain.new("server.example.com"))
      raw = <<10::16, 20::16, 443::16, domain_raw::binary>>
      record = SRV.from_iodata(raw)
      assert %SRV{} = record
    end

    test "parses priority correctly" do
      domain_raw = DNS.to_iodata(Domain.new("server.example.com"))
      raw = <<5::16, 10::16, 80::16, domain_raw::binary>>
      record = SRV.from_iodata(raw)
      {priority, _, _, _} = record.data
      assert priority == 5
    end

    test "parses weight correctly" do
      domain_raw = DNS.to_iodata(Domain.new("server.example.com"))
      raw = <<10::16, 50::16, 80::16, domain_raw::binary>>
      record = SRV.from_iodata(raw)
      {_, weight, _, _} = record.data
      assert weight == 50
    end

    test "parses port correctly" do
      domain_raw = DNS.to_iodata(Domain.new("server.example.com"))
      raw = <<10::16, 20::16, 8443::16, domain_raw::binary>>
      record = SRV.from_iodata(raw)
      {_, _, port, _} = record.data
      assert port == 8443
    end

    test "parses target domain correctly" do
      domain_raw = DNS.to_iodata(Domain.new("target.example.com"))
      raw = <<0::16, 0::16, 80::16, domain_raw::binary>>
      record = SRV.from_iodata(raw)
      {_, _, _, domain} = record.data
      assert domain.value == "target.example.com."
    end

    test "stores raw binary" do
      domain_raw = DNS.to_iodata(Domain.new("server.test.com"))
      raw = <<10::16, 10::16, 80::16, domain_raw::binary>>
      record = SRV.from_iodata(raw)
      assert is_binary(record.raw)
    end
  end

  describe "from_iodata/2" do
    test "accepts message parameter for compression" do
      domain_raw = DNS.to_iodata(Domain.new("server.example.com"))
      raw = <<10::16, 20::16, 443::16, domain_raw::binary>>
      record = SRV.from_iodata(raw, <<>>)
      assert %SRV{} = record
    end

    test "message can be nil" do
      domain_raw = DNS.to_iodata(Domain.new("server.example.com"))
      raw = <<10::16, 20::16, 443::16, domain_raw::binary>>
      record = SRV.from_iodata(raw, nil)
      {priority, _, _, _} = record.data
      assert priority == 10
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'priority weight port target'" do
      record = SRV.new({10, 20, 443, "server.example.com"})
      str = to_string(record)
      assert str == "10 20 443 server.example.com."
    end

    test "includes trailing dot on target" do
      record = SRV.new({0, 0, 80, "web.example.com"})
      str = to_string(record)
      assert String.ends_with?(str, ".")
    end

    test "string interpolation works" do
      record = SRV.new({5, 10, 8080, "api.example.com"})
      result = "SRV: #{record}"
      assert result =~ "SRV:"
      assert result =~ "5 10 8080"
    end

    test "formats all zero values" do
      record = SRV.new({0, 0, 0, "host.example.com"})
      str = to_string(record)
      assert str =~ "0 0 0"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      record = SRV.new({10, 20, 443, "server.example.com"})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, priority::16, _rest::binary>> = iodata
      assert priority == 10
      assert length > 6
    end

    test "length includes priority, weight, port, and target" do
      record = SRV.new({10, 20, 443, "server.example.com"})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length == record.rdlength
    end

    test "wire format has correct order" do
      record = SRV.new({1, 2, 3, "a.com"})
      iodata = DNS.Parameter.to_iodata(record)
      <<_length::16, priority::16, weight::16, port::16, _domain::binary>> = iodata
      assert {priority, weight, port} == {1, 2, 3}
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      original = {10, 50, 443, "server.example.com"}
      record = SRV.new(original)
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      parsed = SRV.from_iodata(raw)
      {priority, weight, port, domain} = parsed.data
      assert priority == 10
      assert weight == 50
      assert port == 443
      assert domain.value == "server.example.com."
    end

    test "round-trip preserves all fields" do
      test_cases = [
        {0, 0, 80, "web.com"},
        {10, 50, 443, "secure.example.com"},
        {100, 100, 8080, "api.service.local"}
      ]

      for {p, w, port, target} <- test_cases do
        record = SRV.new({p, w, port, target})
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
        parsed = SRV.from_iodata(raw)
        {pp, pw, pport, pdomain} = parsed.data
        assert {pp, pw, pport} == {p, w, port}
        assert pdomain.value == "#{target}."
      end
    end
  end

  describe "service location semantics" do
    test "lower priority is preferred" do
      primary = SRV.new({10, 50, 443, "primary.example.com"})
      backup = SRV.new({20, 50, 443, "backup.example.com"})
      {p1, _, _, _} = primary.data
      {p2, _, _, _} = backup.data
      assert p1 < p2
    end

    test "weight for load balancing among same priority" do
      server1 = SRV.new({10, 70, 443, "server1.example.com"})
      server2 = SRV.new({10, 30, 443, "server2.example.com"})
      {_, w1, _, _} = server1.data
      {_, w2, _, _} = server2.data
      # server1 should get 70% of traffic, server2 30%
      assert w1 + w2 == 100
    end

    test "disabled service uses special target" do
      # RFC 2782: target of '.' means service not available
      record = SRV.new({0, 0, 0, "."})
      {_, _, port, domain} = record.data
      assert port == 0
      assert domain.value == "."
    end
  end

  describe "common services" do
    test "HTTP service" do
      record = SRV.new({10, 0, 80, "www.example.com"})
      {_, _, port, _} = record.data
      assert port == 80
    end

    test "HTTPS service" do
      record = SRV.new({10, 0, 443, "www.example.com"})
      {_, _, port, _} = record.data
      assert port == 443
    end

    test "LDAP service" do
      record = SRV.new({0, 0, 389, "ldap.example.com"})
      {_, _, port, _} = record.data
      assert port == 389
    end

    test "Kerberos service" do
      record = SRV.new({0, 100, 88, "kdc.example.com"})
      {_, _, port, _} = record.data
      assert port == 88
    end

    test "SIP service" do
      record = SRV.new({10, 50, 5060, "sip.example.com"})
      {_, _, port, _} = record.data
      assert port == 5060
    end

    test "XMPP service" do
      record = SRV.new({5, 0, 5222, "xmpp.example.com"})
      {_, _, port, _} = record.data
      assert port == 5222
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = SRV.new({10, 20, 443, "server.example.com"})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "max port number (65535)" do
      record = SRV.new({0, 0, 65535, "high-port.example.com"})
      {_, _, port, _} = record.data
      assert port == 65535
    end

    test "max weight (65535)" do
      record = SRV.new({0, 65535, 80, "heavy.example.com"})
      {_, weight, _, _} = record.data
      assert weight == 65535
    end

    test "handles subdomain target" do
      record = SRV.new({10, 0, 443, "api.v2.prod.example.com"})
      {_, _, _, domain} = record.data
      assert domain.value == "api.v2.prod.example.com."
    end
  end
end
