defmodule DNS.Message.EDNS0.Option.ExtendedDNSErrorTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.ExtendedDNSError

  describe "new/1" do
    test "creates ExtendedDNSError option with info code and text" do
      info_code = 1
      extra_text = "DNSSEC validation failed"
      option = ExtendedDNSError.new({info_code, extra_text})
      assert option.code.value == <<15::16>>
      assert option.length == 2 + byte_size(extra_text)
      assert option.data == {info_code, extra_text}
    end

    test "creates ExtendedDNSError option with empty text" do
      info_code = 2
      option = ExtendedDNSError.new({info_code, ""})
      assert option.code.value == <<15::16>>
      assert option.length == 2
      assert option.data == {info_code, ""}
    end
  end

  describe "from_iodata/1" do
    test "parses ExtendedDNSError option from binary" do
      info_code = 1
      extra_text = "DNSSEC validation failed"
      binary = <<15::16, 2 + byte_size(extra_text)::16, info_code::16, extra_text::binary>>
      option = ExtendedDNSError.from_iodata(binary)
      assert option.code.value == <<15::16>>
      assert option.length == 2 + byte_size(extra_text)
      assert option.data == {info_code, extra_text}
    end

    test "parses ExtendedDNSError option without text" do
      info_code = 2
      binary = <<15::16, 2::16, info_code::16>>
      option = ExtendedDNSError.from_iodata(binary)
      assert option.code.value == <<15::16>>
      assert option.length == 2
      assert option.data == {info_code, ""}
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts ExtendedDNSError option to iodata" do
      info_code = 1
      extra_text = "test error"
      option = ExtendedDNSError.new({info_code, extra_text})
      iodata = DNS.Parameter.to_iodata(option)

      assert iodata ==
               <<15::16, 2 + byte_size(extra_text)::16, info_code::16, extra_text::binary>>
    end
  end

  describe "String.Chars protocol" do
    test "converts ExtendedDNSError option with text to string" do
      info_code = 1
      extra_text = "DNSSEC validation failed"
      option = ExtendedDNSError.new({info_code, extra_text})
      assert to_string(option) == "Extended DNS Error: 1 DNSSEC validation failed"
    end

    test "converts ExtendedDNSError option without text to string" do
      info_code = 2
      option = ExtendedDNSError.new({info_code, ""})
      assert to_string(option) == "Extended DNS Error: 2"
    end
  end
end
