defmodule DNS.Message.Record.Data.MXTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.MX.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with {priority, domain} tuples
  - from_iodata/1, from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 1035)
  - Edge cases and priority values
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.MX
  alias DNS.Message.Domain

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(MX)
    end

    test "exports new/1" do
      Code.ensure_loaded!(MX)
      assert Kernel.function_exported?(MX, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(MX)
      assert Kernel.function_exported?(MX, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(MX)
      assert Kernel.function_exported?(MX, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(MX)
      assert is_struct(MX.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %MX{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %MX{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %MX{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %MX{}
      assert Map.has_key?(record, :data)
    end

    test "default type is MX (15)" do
      type = %MX{}.type
      assert type == DNS.ResourceRecordType.new(15)
    end

    test "default raw is nil" do
      assert %MX{}.raw == nil
    end

    test "default data is nil" do
      assert %MX{}.data == nil
    end
  end

  describe "new/1" do
    test "creates MX record from {priority, domain} tuple" do
      record = MX.new({10, "mail.example.com"})
      assert %MX{} = record
      assert {10, %Domain{}} = record.data
    end

    test "stores priority in data tuple" do
      record = MX.new({10, "mail.example.com"})
      {priority, _domain} = record.data
      assert priority == 10
    end

    test "stores domain in data tuple" do
      record = MX.new({10, "mail.example.com"})
      {_priority, domain} = record.data
      assert domain == Domain.new("mail.example.com")
    end

    test "creates record with priority 0" do
      record = MX.new({0, "primary.mail.com"})
      {priority, _} = record.data
      assert priority == 0
    end

    test "creates record with high priority (65535)" do
      record = MX.new({65535, "backup.mail.com"})
      {priority, _} = record.data
      assert priority == 65535
    end

    test "creates record with typical low priority (10)" do
      record = MX.new({10, "mail.example.com"})
      {priority, _} = record.data
      assert priority == 10
    end

    test "creates record with typical backup priority (20)" do
      record = MX.new({20, "mail2.example.com"})
      {priority, _} = record.data
      assert priority == 20
    end

    test "raw field contains binary data" do
      record = MX.new({10, "mail.example.com"})
      assert is_binary(record.raw)
    end

    test "rdlength is domain size plus 2 bytes for priority" do
      domain = Domain.new("mail.example.com")
      record = MX.new({10, "mail.example.com"})
      assert record.rdlength == domain.size + 2
    end

    test "handles subdomain mail servers" do
      record = MX.new({10, "smtp.mail.example.com"})
      {_, domain} = record.data
      assert domain.value == "smtp.mail.example.com."
    end

    test "handles root-relative domains" do
      record = MX.new({10, "mail.example.com."})
      {_, domain} = record.data
      assert domain.value == "mail.example.com."
    end
  end

  describe "from_iodata/1" do
    test "parses binary with priority and domain" do
      # Priority (10) + domain "mail.example.com"
      domain_raw = DNS.to_iodata(Domain.new("mail.example.com"))
      raw = <<10::16, domain_raw::binary>>
      record = MX.from_iodata(raw)
      assert %MX{} = record
      {priority, _} = record.data
      assert priority == 10
    end

    test "parses domain correctly" do
      domain_raw = DNS.to_iodata(Domain.new("mail.example.com"))
      raw = <<10::16, domain_raw::binary>>
      record = MX.from_iodata(raw)
      {_, domain} = record.data
      assert domain.value == "mail.example.com."
    end

    test "stores raw binary" do
      domain_raw = DNS.to_iodata(Domain.new("mx.test.com"))
      raw = <<20::16, domain_raw::binary>>
      record = MX.from_iodata(raw)
      assert is_binary(record.raw)
    end

    test "parses priority 0" do
      domain_raw = DNS.to_iodata(Domain.new("mail.com"))
      raw = <<0::16, domain_raw::binary>>
      record = MX.from_iodata(raw)
      {priority, _} = record.data
      assert priority == 0
    end

    test "parses max priority (65535)" do
      domain_raw = DNS.to_iodata(Domain.new("backup.mail.com"))
      raw = <<65535::16, domain_raw::binary>>
      record = MX.from_iodata(raw)
      {priority, _} = record.data
      assert priority == 65535
    end
  end

  describe "from_iodata/2" do
    test "accepts message parameter for compression" do
      domain_raw = DNS.to_iodata(Domain.new("mail.example.com"))
      raw = <<10::16, domain_raw::binary>>
      record = MX.from_iodata(raw, <<>>)
      assert %MX{} = record
    end

    test "message can be nil" do
      domain_raw = DNS.to_iodata(Domain.new("mail.example.com"))
      raw = <<10::16, domain_raw::binary>>
      record = MX.from_iodata(raw, nil)
      {priority, _} = record.data
      assert priority == 10
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'priority domain'" do
      record = MX.new({10, "mail.example.com"})
      str = to_string(record)
      assert str == "10 mail.example.com."
    end

    test "formats priority 0 correctly" do
      record = MX.new({0, "primary.mail.com"})
      str = to_string(record)
      assert str =~ "0 "
    end

    test "formats high priority correctly" do
      record = MX.new({65535, "backup.mail.com"})
      str = to_string(record)
      assert str =~ "65535 "
    end

    test "string interpolation works" do
      record = MX.new({10, "mail.example.com"})
      result = "MX: #{record}"
      assert result =~ "MX: 10"
      assert result =~ "mail.example.com"
    end

    test "includes trailing dot on domain" do
      record = MX.new({10, "mail.example.com"})
      str = to_string(record)
      assert String.ends_with?(str, ".")
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      record = MX.new({10, "mail.example.com"})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, priority::16, _domain::binary>> = iodata
      assert priority == 10
      assert length > 2
    end

    test "length includes priority and domain" do
      record = MX.new({10, "mail.example.com"})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      domain = Domain.new("mail.example.com")
      assert length == byte_size(DNS.to_iodata(domain)) + 2
    end

    test "wire format priority is first after length" do
      record = MX.new({20, "mx.test.com"})
      <<_length::16, priority::16, _::binary>> = DNS.Parameter.to_iodata(record)
      assert priority == 20
    end

    test "domain follows priority in wire format" do
      record = MX.new({10, "test.com"})
      iodata = DNS.Parameter.to_iodata(record)
      <<_length::16, 10::16, domain_bytes::binary>> = iodata
      # Domain should start with length-prefixed label
      assert byte_size(domain_bytes) > 0
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      original = {10, "mail.example.com"}
      record = MX.new(original)
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      parsed = MX.from_iodata(raw)
      {priority, domain} = parsed.data
      assert priority == 10
      assert domain.value == "mail.example.com."
    end

    test "round-trip preserves priority" do
      for priority <- [0, 10, 20, 100, 65535] do
        record = MX.new({priority, "mail.test.com"})
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
        parsed = MX.from_iodata(raw)
        {parsed_priority, _} = parsed.data
        assert parsed_priority == priority
      end
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = MX.new({10, "mail.example.com"})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "handles single-label domain" do
      record = MX.new({10, "localhost"})
      {_, domain} = record.data
      assert domain.value == "localhost."
    end

    test "handles multi-level subdomain" do
      record = MX.new({10, "smtp.mail.server.example.com"})
      {_, domain} = record.data
      assert domain.value == "smtp.mail.server.example.com."
    end

    test "different priorities for same domain" do
      record1 = MX.new({10, "mail.example.com"})
      record2 = MX.new({20, "mail.example.com"})
      {priority1, _} = record1.data
      {priority2, _} = record2.data
      assert priority1 != priority2
    end
  end
end
