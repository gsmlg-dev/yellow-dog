defmodule DNS.Message.Record.Data.CAATest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.CAA.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with {flags, tag, value} tuple
  - from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 6844)
  - Certificate Authority Authorization semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.CAA

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(CAA)
    end

    test "exports new/1" do
      Code.ensure_loaded!(CAA)
      assert Kernel.function_exported?(CAA, :new, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(CAA)
      assert Kernel.function_exported?(CAA, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(CAA)
      assert is_struct(CAA.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %CAA{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %CAA{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %CAA{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %CAA{}
      assert Map.has_key?(record, :data)
    end

    test "default type is CAA (257)" do
      type = %CAA{}.type
      assert type == DNS.ResourceRecordType.new(257)
    end

    test "default raw is nil" do
      assert %CAA{}.raw == nil
    end

    test "default data is nil" do
      assert %CAA{}.data == nil
    end
  end

  describe "new/1" do
    test "creates CAA record from 3-element tuple" do
      record = CAA.new({0, "issue", "letsencrypt.org"})
      assert %CAA{} = record
    end

    test "stores flags field" do
      record = CAA.new({128, "issue", "digicert.com"})
      {flags, _, _} = record.data
      assert flags == 128
    end

    test "stores tag field" do
      record = CAA.new({0, "issue", "letsencrypt.org"})
      {_, tag, _} = record.data
      assert tag == "issue"
    end

    test "stores value field" do
      record = CAA.new({0, "issue", "letsencrypt.org"})
      {_, _, value} = record.data
      assert value == "letsencrypt.org"
    end

    test "creates record with issue tag" do
      record = CAA.new({0, "issue", "ca.example.com"})
      {_, tag, _} = record.data
      assert tag == "issue"
    end

    test "creates record with issuewild tag" do
      record = CAA.new({0, "issuewild", "wildcard-ca.example.com"})
      {_, tag, _} = record.data
      assert tag == "issuewild"
    end

    test "creates record with iodef tag" do
      record = CAA.new({0, "iodef", "mailto:security@example.com"})
      {_, tag, _} = record.data
      assert tag == "iodef"
    end

    test "creates record with contactemail tag" do
      record = CAA.new({0, "contactemail", "admin@example.com"})
      {_, tag, _} = record.data
      assert tag == "contactemail"
    end

    test "creates record with contactphone tag" do
      record = CAA.new({0, "contactphone", "+1-555-123-4567"})
      {_, tag, _} = record.data
      assert tag == "contactphone"
    end

    test "creates record with critical flag (128)" do
      record = CAA.new({128, "issue", "ca.example.com"})
      {flags, _, _} = record.data
      assert flags == 128
    end

    test "creates record without critical flag (0)" do
      record = CAA.new({0, "issue", "ca.example.com"})
      {flags, _, _} = record.data
      assert flags == 0
    end

    test "raw field contains binary data" do
      record = CAA.new({0, "issue", "letsencrypt.org"})
      assert is_binary(record.raw)
    end

    test "rdlength matches expected size" do
      tag = "issue"
      value = "letsencrypt.org"
      record = CAA.new({0, tag, value})
      # 1 (flags) + 1 (tag length) + tag size + value size
      expected_size = 1 + 1 + byte_size(tag) + byte_size(value)
      assert record.rdlength == expected_size
    end

    test "handles empty value" do
      record = CAA.new({0, "issue", ""})
      {_, _, value} = record.data
      assert value == ""
    end

    test "handles value with semicolon parameters" do
      record = CAA.new({0, "issue", "ca.example.net; account=12345"})
      {_, _, value} = record.data
      assert value == "ca.example.net; account=12345"
    end
  end

  describe "from_iodata/2" do
    test "parses CAA from binary" do
      tag = "issue"
      value = "letsencrypt.org"
      raw = <<0::8, byte_size(tag)::8, tag::binary, value::binary>>
      record = CAA.from_iodata(raw, nil)
      assert %CAA{} = record
    end

    test "parses flags correctly" do
      tag = "issue"
      value = "ca.com"
      raw = <<128::8, byte_size(tag)::8, tag::binary, value::binary>>
      record = CAA.from_iodata(raw)
      {flags, _, _} = record.data
      assert flags == 128
    end

    test "parses tag correctly" do
      tag = "issuewild"
      value = "ca.com"
      raw = <<0::8, byte_size(tag)::8, tag::binary, value::binary>>
      record = CAA.from_iodata(raw)
      {_, parsed_tag, _} = record.data
      assert parsed_tag == tag
    end

    test "parses value correctly" do
      tag = "issue"
      value = "letsencrypt.org"
      raw = <<0::8, byte_size(tag)::8, tag::binary, value::binary>>
      record = CAA.from_iodata(raw)
      {_, _, parsed_value} = record.data
      assert parsed_value == value
    end

    test "stores raw binary" do
      tag = "issue"
      value = "ca.com"
      raw = <<0::8, byte_size(tag)::8, tag::binary, value::binary>>
      record = CAA.from_iodata(raw)
      assert record.raw == raw
    end

    test "parses iodef tag with mailto" do
      tag = "iodef"
      value = "mailto:security@example.com"
      raw = <<0::8, byte_size(tag)::8, tag::binary, value::binary>>
      record = CAA.from_iodata(raw)
      {_, parsed_tag, parsed_value} = record.data
      assert parsed_tag == "iodef"
      assert parsed_value == value
    end

    test "parses iodef tag with https" do
      tag = "iodef"
      value = "https://example.com/report"
      raw = <<0::8, byte_size(tag)::8, tag::binary, value::binary>>
      record = CAA.from_iodata(raw)
      {_, _, parsed_value} = record.data
      assert parsed_value == value
    end

    test "parses empty value" do
      tag = "issue"
      raw = <<0::8, byte_size(tag)::8, tag::binary>>
      record = CAA.from_iodata(raw)
      {_, _, parsed_value} = record.data
      assert parsed_value == ""
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'flags tag \"value\"'" do
      record = CAA.new({0, "issue", "letsencrypt.org"})
      str = to_string(record)
      assert str == "0 issue \"letsencrypt.org\""
    end

    test "includes critical flag" do
      record = CAA.new({128, "issue", "digicert.com"})
      str = to_string(record)
      assert str == "128 issue \"digicert.com\""
    end

    test "string interpolation works" do
      record = CAA.new({0, "issue", "ca.com"})
      result = "CAA: #{record}"
      assert result =~ "CAA:"
      assert result =~ "issue"
    end

    test "formats issuewild correctly" do
      record = CAA.new({0, "issuewild", "wildcard-ca.com"})
      str = to_string(record)
      assert str == "0 issuewild \"wildcard-ca.com\""
    end

    test "formats iodef with mailto" do
      record = CAA.new({0, "iodef", "mailto:admin@example.com"})
      str = to_string(record)
      assert str == "0 iodef \"mailto:admin@example.com\""
    end

    test "formats empty value" do
      record = CAA.new({0, "issue", ""})
      str = to_string(record)
      assert str == "0 issue \"\""
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      tag = "issue"
      value = "letsencrypt.org"
      record = CAA.new({0, tag, value})
      iodata = DNS.Parameter.to_iodata(record)
      expected_size = 1 + 1 + byte_size(tag) + byte_size(value)
      <<length::16, flags::8, tag_len::8, rest::binary>> = iodata
      assert length == expected_size
      assert flags == 0
      assert tag_len == byte_size(tag)
      <<parsed_tag::binary-size(tag_len), parsed_value::binary>> = rest
      assert parsed_tag == tag
      assert parsed_value == value
    end

    test "length prefix matches rdlength" do
      record = CAA.new({128, "issuewild", "ca.example.com"})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length == record.rdlength
    end

    test "wire format for empty value" do
      tag = "issue"
      record = CAA.new({0, tag, ""})
      iodata = DNS.Parameter.to_iodata(record)
      expected_size = 1 + 1 + byte_size(tag)
      <<length::16, _rest::binary>> = iodata
      assert length == expected_size
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      original = CAA.new({0, "issue", "letsencrypt.org"})
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = CAA.from_iodata(raw)
      assert parsed.data == original.data
    end

    test "round-trip preserves all fields" do
      test_cases = [
        {0, "issue", "letsencrypt.org"},
        {128, "issuewild", "digicert.com"},
        {0, "iodef", "mailto:security@example.com"},
        {0, "contactemail", "admin@example.com"},
        {0, "issue", ""}
      ]

      for {flags, tag, value} <- test_cases do
        original = CAA.new({flags, tag, value})
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
        parsed = CAA.from_iodata(raw)
        assert parsed.data == {flags, tag, value}
      end
    end
  end

  describe "CA Authorization semantics" do
    test "issue tag authorizes CA for domain" do
      record = CAA.new({0, "issue", "letsencrypt.org"})
      {_, tag, _} = record.data
      assert tag == "issue"
    end

    test "issuewild tag authorizes CA for wildcard" do
      record = CAA.new({0, "issuewild", "digicert.com"})
      {_, tag, _} = record.data
      assert tag == "issuewild"
    end

    test "iodef tag specifies incident reporting" do
      record = CAA.new({0, "iodef", "mailto:security@example.com"})
      {_, tag, value} = record.data
      assert tag == "iodef"
      assert value =~ "mailto:"
    end

    test "empty issue value denies all CAs" do
      # RFC 6844: empty value means no CA is authorized
      record = CAA.new({0, "issue", ""})
      {_, tag, value} = record.data
      assert tag == "issue"
      assert value == ""
    end

    test "critical flag requires processing" do
      # RFC 6844: critical flag must be understood
      record = CAA.new({128, "issue", "ca.com"})
      {flags, _, _} = record.data
      assert flags == 128
    end

    test "non-critical flag is advisory" do
      record = CAA.new({0, "issue", "ca.com"})
      {flags, _, _} = record.data
      assert flags == 0
    end
  end

  describe "common CAA configurations" do
    test "single CA authorization" do
      record = CAA.new({0, "issue", "letsencrypt.org"})
      {flags, tag, value} = record.data
      assert {flags, tag} == {0, "issue"}
      assert value == "letsencrypt.org"
    end

    test "deny all certificate issuance" do
      record = CAA.new({0, "issue", ";"})
      {_, tag, value} = record.data
      assert tag == "issue"
      assert value == ";"
    end

    test "wildcard-only CA" do
      record = CAA.new({0, "issuewild", "wildcard-ca.com"})
      {_, tag, _} = record.data
      assert tag == "issuewild"
    end

    test "incident reporting via email" do
      record = CAA.new({0, "iodef", "mailto:caa@example.com"})
      {_, tag, value} = record.data
      assert tag == "iodef"
      assert String.starts_with?(value, "mailto:")
    end

    test "incident reporting via HTTPS" do
      record = CAA.new({0, "iodef", "https://example.com/caa-report"})
      {_, tag, value} = record.data
      assert tag == "iodef"
      assert String.starts_with?(value, "https:")
    end

    test "CA with account binding" do
      record = CAA.new({0, "issue", "letsencrypt.org; accounturi=https://acme.example.com/acct/1"})
      {_, _, value} = record.data
      assert value =~ "accounturi="
    end

    test "CA with validation methods" do
      record = CAA.new({0, "issue", "ca.example.com; validationmethods=dns-01"})
      {_, _, value} = record.data
      assert value =~ "validationmethods="
    end
  end

  describe "RFC 8659 extensions" do
    test "contactemail for domain contact" do
      record = CAA.new({0, "contactemail", "admin@example.com"})
      {_, tag, _} = record.data
      assert tag == "contactemail"
    end

    test "contactphone for domain contact" do
      record = CAA.new({0, "contactphone", "+1-555-123-4567"})
      {_, tag, _} = record.data
      assert tag == "contactphone"
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = CAA.new({0, "issue", "ca.com"})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "long value" do
      long_value = String.duplicate("a", 200)
      record = CAA.new({0, "issue", long_value})
      {_, _, value} = record.data
      assert byte_size(value) == 200
    end

    test "unicode in value" do
      record = CAA.new({0, "iodef", "mailto:admin@例え.jp"})
      {_, _, value} = record.data
      assert value =~ "例え"
    end

    test "max flags value (255)" do
      record = CAA.new({255, "issue", "ca.com"})
      {flags, _, _} = record.data
      assert flags == 255
    end

    test "single character tag" do
      record = CAA.new({0, "x", "value"})
      {_, tag, _} = record.data
      assert tag == "x"
    end

    test "value with special characters" do
      record = CAA.new({0, "issue", "ca.com; key=\"value with spaces\""})
      {_, _, value} = record.data
      assert value =~ "value with spaces"
    end
  end
end
