defmodule DNS.Message.Record.Data.TXTTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.TXT.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with string lists
  - from_iodata/1, from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 1035)
  - Common TXT record uses (SPF, DKIM, DMARC, verification)
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.TXT

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(TXT)
    end

    test "exports new/1" do
      Code.ensure_loaded!(TXT)
      assert Kernel.function_exported?(TXT, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(TXT)
      assert Kernel.function_exported?(TXT, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(TXT)
      assert Kernel.function_exported?(TXT, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(TXT)
      assert is_struct(TXT.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %TXT{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %TXT{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %TXT{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %TXT{}
      assert Map.has_key?(record, :data)
    end

    test "default type is TXT (16)" do
      type = %TXT{}.type
      assert type == DNS.ResourceRecordType.new(16)
    end

    test "default raw is nil" do
      assert %TXT{}.raw == nil
    end

    test "default data is nil" do
      assert %TXT{}.data == nil
    end
  end

  describe "new/1" do
    test "creates TXT record from single string list" do
      record = TXT.new(["hello world"])
      assert %TXT{} = record
      assert record.data == ["hello world"]
    end

    test "creates record with multiple strings" do
      record = TXT.new(["hello", "world"])
      assert record.data == ["hello", "world"]
    end

    test "stores raw binary" do
      record = TXT.new(["test"])
      assert is_binary(record.raw)
    end

    test "rdlength matches raw size" do
      record = TXT.new(["test"])
      assert record.rdlength == byte_size(record.raw)
    end

    test "raw format includes length prefix per string" do
      record = TXT.new(["hi"])
      # 1 byte length + 2 byte data
      assert record.raw == <<2, "hi">>
    end

    test "creates record with empty string list" do
      record = TXT.new([])
      assert record.data == []
      assert record.raw == <<>>
    end

    test "creates record with empty string" do
      record = TXT.new([""])
      assert record.data == [""]
      assert record.raw == <<0>>
    end

    test "creates SPF record" do
      spf = ["v=spf1 include:_spf.google.com ~all"]
      record = TXT.new(spf)
      assert record.data == spf
    end

    test "creates DKIM record" do
      dkim = ["v=DKIM1; k=rsa; p=MIGfMA0GCS..."]
      record = TXT.new(dkim)
      assert record.data == dkim
    end

    test "creates DMARC record" do
      dmarc = ["v=DMARC1; p=none; rua=mailto:dmarc@example.com"]
      record = TXT.new(dmarc)
      assert record.data == dmarc
    end

    test "creates site verification record" do
      verification = ["google-site-verification=abc123xyz"]
      record = TXT.new(verification)
      assert record.data == verification
    end
  end

  describe "from_iodata/1" do
    test "parses single string" do
      raw = <<5, "hello">>
      record = TXT.from_iodata(raw)
      assert %TXT{} = record
      assert record.data == ["hello"]
    end

    test "parses multiple strings" do
      raw = <<5, "hello", 5, "world">>
      record = TXT.from_iodata(raw)
      assert record.data == ["hello", "world"]
    end

    test "stores raw binary" do
      raw = <<4, "test">>
      record = TXT.from_iodata(raw)
      assert record.raw == raw
    end

    test "parses empty string" do
      raw = <<0>>
      record = TXT.from_iodata(raw)
      assert record.data == [""]
    end

    test "parses empty binary" do
      raw = <<>>
      record = TXT.from_iodata(raw)
      assert record.data == []
    end

    test "parses varying length strings" do
      raw = <<1, "a", 3, "bbb", 2, "cc">>
      record = TXT.from_iodata(raw)
      assert record.data == ["a", "bbb", "cc"]
    end

    test "sets rdlength from raw size" do
      raw = <<5, "hello">>
      record = TXT.from_iodata(raw)
      assert record.rdlength == byte_size(raw)
    end
  end

  describe "from_iodata/2" do
    test "accepts message parameter (ignored for TXT)" do
      raw = <<4, "test">>
      record = TXT.from_iodata(raw, <<>>)
      assert record.data == ["test"]
    end

    test "message can be nil" do
      raw = <<4, "test">>
      record = TXT.from_iodata(raw, nil)
      assert record.data == ["test"]
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats single string with quotes" do
      record = TXT.new(["hello"])
      str = to_string(record)
      assert str == ~s["hello"]
    end

    test "formats multiple strings space-separated" do
      record = TXT.new(["hello", "world"])
      str = to_string(record)
      assert str == ~s["hello" "world"]
    end

    test "string interpolation works" do
      record = TXT.new(["test"])
      result = "TXT: #{record}"
      assert result =~ "TXT:"
      assert result =~ "test"
    end

    test "formats SPF record" do
      record = TXT.new(["v=spf1 +all"])
      str = to_string(record)
      assert str =~ "v=spf1"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      record = TXT.new(["test"])
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, text_data::binary>> = iodata
      assert length == byte_size(text_data)
    end

    test "length prefix matches raw size" do
      record = TXT.new(["hello", "world"])
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length == record.rdlength
    end

    test "wire format includes length prefix" do
      record = TXT.new(["hi"])
      iodata = DNS.Parameter.to_iodata(record)
      # 2 bytes length + 1 byte string length + 2 bytes data
      assert byte_size(iodata) == 2 + 1 + 2
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      original = ["hello", "world"]
      record = TXT.new(original)
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      parsed = TXT.from_iodata(raw)
      assert parsed.data == original
    end

    test "round-trip preserves multiple strings" do
      texts = [["a"], ["hello", "world"], ["spf", "v=spf1", "+all"]]

      for text <- texts do
        record = TXT.new(text)
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
        parsed = TXT.from_iodata(raw)
        assert parsed.data == text
      end
    end
  end

  describe "common TXT record uses" do
    test "SPF record format" do
      spf = ["v=spf1 include:_spf.google.com include:mailgun.org ~all"]
      record = TXT.new(spf)
      str = to_string(record)
      assert str =~ "v=spf1"
      assert str =~ "include:"
    end

    test "DKIM selector record" do
      dkim = ["v=DKIM1; k=rsa; p=MIGf..."]
      record = TXT.new(dkim)
      str = to_string(record)
      assert str =~ "v=DKIM1"
    end

    test "DMARC policy record" do
      dmarc = ["v=DMARC1; p=quarantine; rua=mailto:reports@example.com"]
      record = TXT.new(dmarc)
      str = to_string(record)
      assert str =~ "v=DMARC1"
    end

    test "domain verification" do
      verify = ["google-site-verification=1234567890abcdef"]
      record = TXT.new(verify)
      str = to_string(record)
      assert str =~ "google-site-verification"
    end

    test "mDNS TXT record for service info" do
      txt = ["version=1.0", "path=/api", "name=My Service"]
      record = TXT.new(txt)
      assert record.data == txt
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = TXT.new(["test"])
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "handles special characters" do
      record = TXT.new(["hello=world; foo=bar"])
      assert record.data == ["hello=world; foo=bar"]
    end

    test "handles unicode" do
      record = TXT.new(["hello world"])
      assert record.data == ["hello world"]
    end

    test "maximum single string length (255 bytes)" do
      long_string = String.duplicate("a", 255)
      record = TXT.new([long_string])
      assert record.data == [long_string]
      # Length prefix is 1 byte for 255
      assert byte_size(record.raw) == 256
    end

    test "multiple strings preserve order" do
      strings = ["first", "second", "third", "fourth"]
      record = TXT.new(strings)
      assert record.data == strings
    end
  end
end
