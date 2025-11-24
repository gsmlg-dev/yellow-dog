defmodule DNS.Message.Record.Data.CAATest do
  use ExUnit.Case
  alias DNS.Message.Record.Data.CAA

  describe "new/1" do
    test "creates CAA record with issue tag" do
      flags = 0
      tag = "issue"
      value = "letsencrypt.org"

      caa = CAA.new({flags, tag, value})

      assert caa.type.value == <<257::16>>
      assert caa.data == {flags, tag, value}

      expected_raw = <<flags::8, byte_size(tag)::8, tag::binary, value::binary>>
      assert caa.raw == expected_raw
      assert caa.rdlength == 1 + 1 + byte_size(tag) + byte_size(value)
    end

    test "creates CAA record with issuewild tag" do
      # Critical bit set
      flags = 128
      tag = "issuewild"
      value = "digicert.com"

      caa = CAA.new({flags, tag, value})

      assert caa.data == {flags, tag, value}
    end

    test "creates CAA record with iodef tag" do
      flags = 0
      tag = "iodef"
      value = "mailto:security@example.com"

      caa = CAA.new({flags, tag, value})

      assert caa.data == {flags, tag, value}
    end

    test "handles CAA record with empty value" do
      flags = 0
      tag = "issue"
      value = ""

      caa = CAA.new({flags, tag, value})

      assert caa.data == {flags, tag, value}
      assert caa.rdlength == 1 + 1 + byte_size(tag) + 0
    end

    test "handles CAA record with special characters" do
      flags = 0
      tag = "issue"
      value = "ca.example.net; account=12345"

      caa = CAA.new({flags, tag, value})

      assert caa.data == {flags, tag, value}
    end
  end

  describe "from_iodata/2" do
    test "parses CAA record correctly" do
      flags = 0
      tag = "issue"
      value = "letsencrypt.org"
      raw = <<flags::8, byte_size(tag)::8, tag::binary, value::binary>>

      caa = CAA.from_iodata(raw)

      assert caa.type.value == <<257::16>>
      assert caa.data == {flags, tag, value}
      assert caa.raw == raw
    end

    test "parses CAA record with critical flag" do
      flags = 128
      tag = "issuewild"
      value = "digicert.com"
      raw = <<flags::8, byte_size(tag)::8, tag::binary, value::binary>>

      caa = CAA.from_iodata(raw)

      assert caa.data == {flags, tag, value}
    end

    test "parses CAA record with iodef" do
      flags = 0
      tag = "iodef"
      value = "mailto:security@example.com"
      raw = <<flags::8, byte_size(tag)::8, tag::binary, value::binary>>

      caa = CAA.from_iodata(raw)

      assert caa.data == {flags, tag, value}
    end

    test "parses CAA record with empty value" do
      flags = 0
      tag = "issue"
      value = ""
      raw = <<flags::8, byte_size(tag)::8, tag::binary>>

      caa = CAA.from_iodata(raw)

      assert caa.data == {flags, tag, value}
      assert caa.rdlength == 1 + 1 + byte_size(tag) + 0
    end

    test "parses CAA record with complex value" do
      flags = 0
      tag = "issue"
      value = "ca.example.net; policy=ev; validationmethods=dns-01"
      raw = <<flags::8, byte_size(tag)::8, tag::binary, value::binary>>

      caa = CAA.from_iodata(raw)

      assert caa.data == {flags, tag, value}
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts CAA record to iodata" do
      flags = 0
      tag = "issue"
      value = "letsencrypt.org"
      caa = CAA.new({flags, tag, value})

      iodata = DNS.Parameter.to_iodata(caa)
      expected_size = 1 + 1 + byte_size(tag) + byte_size(value)
      expected = <<expected_size::16, flags::8, byte_size(tag)::8, tag::binary, value::binary>>

      assert iodata == expected
    end

    test "converts CAA record with critical flag to iodata" do
      flags = 128
      tag = "issuewild"
      value = "digicert.com"
      caa = CAA.new({flags, tag, value})

      iodata = DNS.Parameter.to_iodata(caa)
      expected_size = 1 + 1 + byte_size(tag) + byte_size(value)
      expected = <<expected_size::16, flags::8, byte_size(tag)::8, tag::binary, value::binary>>

      assert iodata == expected
    end

    test "converts CAA record with empty value to iodata" do
      flags = 0
      tag = "issue"
      value = ""
      caa = CAA.new({flags, tag, value})

      iodata = DNS.Parameter.to_iodata(caa)
      expected = <<7::16, flags::8, byte_size(tag)::8, tag::binary>>

      assert iodata == expected
    end
  end

  describe "String.Chars protocol" do
    test "converts CAA record to string" do
      flags = 0
      tag = "issue"
      value = "letsencrypt.org"
      caa = CAA.new({flags, tag, value})

      str = to_string(caa)

      assert str == "#{flags} #{tag} \"#{value}\""
    end

    test "converts CAA record with critical flag to string" do
      flags = 128
      tag = "issuewild"
      value = "digicert.com"
      caa = CAA.new({flags, tag, value})

      str = to_string(caa)

      assert str == "#{flags} #{tag} \"#{value}\""
    end

    test "converts CAA record with special characters to string" do
      flags = 0
      tag = "iodef"
      value = "mailto:security@example.com"
      caa = CAA.new({flags, tag, value})

      str = to_string(caa)

      assert str == "#{flags} #{tag} \"#{value}\""
    end

    test "converts CAA record with empty value to string" do
      flags = 0
      tag = "issue"
      value = ""
      caa = CAA.new({flags, tag, value})

      str = to_string(caa)

      assert str == "#{flags} #{tag} \"\""
    end
  end
end
