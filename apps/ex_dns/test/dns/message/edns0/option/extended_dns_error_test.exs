defmodule DNS.Message.EDNS0.Option.ExtendedDNSErrorTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.ExtendedDNSError.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with {info_code, extra_text} tuple
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 8914)
  - Extended DNS Error semantics and info codes
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.ExtendedDNSError
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(ExtendedDNSError)
    end

    test "exports new/1" do
      Code.ensure_loaded!(ExtendedDNSError)
      assert Kernel.function_exported?(ExtendedDNSError, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(ExtendedDNSError)
      assert Kernel.function_exported?(ExtendedDNSError, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(ExtendedDNSError)
      assert is_struct(ExtendedDNSError.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %ExtendedDNSError{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %ExtendedDNSError{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %ExtendedDNSError{}
      assert Map.has_key?(option, :data)
    end

    test "default code is ExtendedDNSError (15)" do
      option = %ExtendedDNSError{}
      assert option.code == OptionCode.new(15)
    end

    test "default length is nil" do
      option = %ExtendedDNSError{}
      assert option.length == nil
    end

    test "default data is nil" do
      option = %ExtendedDNSError{}
      assert option.data == nil
    end
  end

  describe "new/1" do
    test "creates ExtendedDNSError option with info code and text" do
      info_code = 1
      extra_text = "DNSSEC validation failed"
      option = ExtendedDNSError.new({info_code, extra_text})
      assert %ExtendedDNSError{} = option
    end

    test "stores info_code and extra_text as tuple" do
      info_code = 1
      extra_text = "DNSSEC validation failed"
      option = ExtendedDNSError.new({info_code, extra_text})
      assert option.data == {info_code, extra_text}
    end

    test "calculates length as 2 + text size" do
      extra_text = "DNSSEC validation failed"
      option = ExtendedDNSError.new({1, extra_text})
      assert option.length == 2 + byte_size(extra_text)
    end

    test "option code is ExtendedDNSError (15)" do
      option = ExtendedDNSError.new({1, "error"})
      assert option.code.value == <<15::16>>
    end

    test "creates ExtendedDNSError option with empty text" do
      info_code = 2
      option = ExtendedDNSError.new({info_code, ""})
      assert option.code.value == <<15::16>>
      assert option.length == 2
      assert option.data == {info_code, ""}
    end

    test "creates option with zero info code" do
      option = ExtendedDNSError.new({0, "Other error"})
      assert elem(option.data, 0) == 0
    end

    test "creates option with max info code (65535)" do
      option = ExtendedDNSError.new({65535, "Reserved"})
      assert elem(option.data, 0) == 65535
    end

    test "handles UTF-8 extra text" do
      # UTF-8 text with multibyte characters
      utf8_text = "Fehler: ungültig"
      option = ExtendedDNSError.new({1, utf8_text})
      assert elem(option.data, 1) == utf8_text
      # Length includes UTF-8 byte count, not character count
      assert option.length == 2 + byte_size(utf8_text)
    end

    test "handles long extra text" do
      long_text = String.duplicate("error description ", 50)
      option = ExtendedDNSError.new({1, long_text})
      assert option.length == 2 + byte_size(long_text)
    end
  end

  describe "from_iodata/1" do
    test "parses ExtendedDNSError option from binary" do
      info_code = 1
      extra_text = "DNSSEC validation failed"
      binary = <<15::16, 2 + byte_size(extra_text)::16, info_code::16, extra_text::binary>>
      option = ExtendedDNSError.from_iodata(binary)
      assert %ExtendedDNSError{} = option
    end

    test "parses info_code correctly" do
      binary = <<15::16, 2::16, 23::16>>
      option = ExtendedDNSError.from_iodata(binary)
      assert elem(option.data, 0) == 23
    end

    test "parses extra_text correctly" do
      extra_text = "Network unreachable"
      binary = <<15::16, 2 + byte_size(extra_text)::16, 1::16, extra_text::binary>>
      option = ExtendedDNSError.from_iodata(binary)
      assert elem(option.data, 1) == extra_text
    end

    test "parses length correctly" do
      extra_text = "DNSSEC validation failed"
      binary = <<15::16, 2 + byte_size(extra_text)::16, 1::16, extra_text::binary>>
      option = ExtendedDNSError.from_iodata(binary)
      assert option.length == 2 + byte_size(extra_text)
    end

    test "parses ExtendedDNSError option without text" do
      info_code = 2
      binary = <<15::16, 2::16, info_code::16>>
      option = ExtendedDNSError.from_iodata(binary)
      assert option.code.value == <<15::16>>
      assert option.length == 2
      assert option.data == {info_code, ""}
    end

    test "parses zero info code" do
      binary = <<15::16, 2::16, 0::16>>
      option = ExtendedDNSError.from_iodata(binary)
      assert elem(option.data, 0) == 0
    end

    test "parses max info code (65535)" do
      binary = <<15::16, 2::16, 65535::16>>
      option = ExtendedDNSError.from_iodata(binary)
      assert elem(option.data, 0) == 65535
    end

    test "parses long extra text" do
      long_text = String.duplicate("x", 200)
      binary = <<15::16, 2 + byte_size(long_text)::16, 1::16, long_text::binary>>
      option = ExtendedDNSError.from_iodata(binary)
      assert elem(option.data, 1) == long_text
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      info_code = 1
      extra_text = "test error"
      option = ExtendedDNSError.new({info_code, extra_text})
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<15::16, 2 + byte_size(extra_text)::16, info_code::16, extra_text::binary>>
    end

    test "wire format starts with option code 15" do
      option = ExtendedDNSError.new({1, "error"})
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 15
    end

    test "wire format has correct length" do
      extra_text = "validation failed"
      option = ExtendedDNSError.new({1, extra_text})
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 2 + byte_size(extra_text)
    end

    test "encodes empty extra text" do
      option = ExtendedDNSError.new({1, ""})
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<15::16, 2::16, 1::16>>
    end

    test "encodes info_code as 16-bit unsigned" do
      option = ExtendedDNSError.new({12345, ""})
      <<_code::16, _length::16, info_code::16>> = DNS.Parameter.to_iodata(option)
      assert info_code == 12345
    end

    test "encodes extra_text as UTF-8 binary" do
      extra_text = "Test message"
      option = ExtendedDNSError.new({1, extra_text})
      <<_code::16, _length::16, _info::16, text::binary>> = DNS.Parameter.to_iodata(option)
      assert text == extra_text
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'Extended DNS Error: info_code extra_text'" do
      option = ExtendedDNSError.new({1, "DNSSEC validation failed"})
      assert to_string(option) == "Extended DNS Error: 1 DNSSEC validation failed"
    end

    test "formats without extra text" do
      option = ExtendedDNSError.new({2, ""})
      assert to_string(option) == "Extended DNS Error: 2"
    end

    test "includes info code" do
      option = ExtendedDNSError.new({23, ""})
      str = to_string(option)
      assert str =~ "23"
    end

    test "includes extra text when present" do
      option = ExtendedDNSError.new({1, "Network error"})
      str = to_string(option)
      assert str =~ "Network error"
    end

    test "string interpolation works" do
      option = ExtendedDNSError.new({1, "error"})
      result = "Option: #{option}"
      assert result =~ "Extended DNS Error:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = ExtendedDNSError.new({1, "test error"})
      iodata = DNS.Parameter.to_iodata(original)
      parsed = ExtendedDNSError.from_iodata(iodata)
      assert parsed.data == original.data
      assert parsed.length == original.length
    end

    test "round-trip preserves empty extra text" do
      original = ExtendedDNSError.new({5, ""})
      iodata = DNS.Parameter.to_iodata(original)
      parsed = ExtendedDNSError.from_iodata(iodata)
      assert parsed.data == {5, ""}
    end

    test "round-trip preserves info code" do
      for info_code <- [0, 1, 100, 1000, 65535] do
        original = ExtendedDNSError.new({info_code, "test"})
        iodata = DNS.Parameter.to_iodata(original)
        parsed = ExtendedDNSError.from_iodata(iodata)
        assert elem(parsed.data, 0) == info_code
      end
    end

    test "round-trip preserves various extra texts" do
      texts = [
        "",
        "Short",
        "Longer error message with details",
        String.duplicate("x", 100)
      ]

      for text <- texts do
        original = ExtendedDNSError.new({1, text})
        iodata = DNS.Parameter.to_iodata(original)
        parsed = ExtendedDNSError.from_iodata(iodata)
        assert elem(parsed.data, 1) == text
      end
    end
  end

  describe "RFC 8914 info codes" do
    # RFC 8914 defines specific info codes

    test "info code 0: Other" do
      option = ExtendedDNSError.new({0, "Other error"})
      assert elem(option.data, 0) == 0
    end

    test "info code 1: Unsupported DNSKEY Algorithm" do
      option = ExtendedDNSError.new({1, "Algorithm not supported"})
      assert elem(option.data, 0) == 1
    end

    test "info code 2: Unsupported DS Digest Type" do
      option = ExtendedDNSError.new({2, "DS digest not supported"})
      assert elem(option.data, 0) == 2
    end

    test "info code 3: Stale Answer" do
      option = ExtendedDNSError.new({3, "Using stale data"})
      assert elem(option.data, 0) == 3
    end

    test "info code 4: Forged Answer" do
      option = ExtendedDNSError.new({4, "Answer was forged"})
      assert elem(option.data, 0) == 4
    end

    test "info code 5: DNSSEC Indeterminate" do
      option = ExtendedDNSError.new({5, "DNSSEC status unknown"})
      assert elem(option.data, 0) == 5
    end

    test "info code 6: DNSSEC Bogus" do
      option = ExtendedDNSError.new({6, "DNSSEC validation failed"})
      assert elem(option.data, 0) == 6
    end

    test "info code 7: Signature Expired" do
      option = ExtendedDNSError.new({7, "RRSIG expired"})
      assert elem(option.data, 0) == 7
    end

    test "info code 8: Signature Not Yet Valid" do
      option = ExtendedDNSError.new({8, "RRSIG not yet valid"})
      assert elem(option.data, 0) == 8
    end

    test "info code 9: DNSKEY Missing" do
      option = ExtendedDNSError.new({9, "Required DNSKEY not found"})
      assert elem(option.data, 0) == 9
    end

    test "info code 10: RRSIGs Missing" do
      option = ExtendedDNSError.new({10, "Required RRSIG not found"})
      assert elem(option.data, 0) == 10
    end

    test "info code 11: No Zone Key Bit Set" do
      option = ExtendedDNSError.new({11, "Zone key bit not set"})
      assert elem(option.data, 0) == 11
    end

    test "info code 12: NSEC Missing" do
      option = ExtendedDNSError.new({12, "Required NSEC not found"})
      assert elem(option.data, 0) == 12
    end

    test "info code 13: Cached Error" do
      option = ExtendedDNSError.new({13, "Error from cache"})
      assert elem(option.data, 0) == 13
    end

    test "info code 14: Not Ready" do
      option = ExtendedDNSError.new({14, "Server not ready"})
      assert elem(option.data, 0) == 14
    end

    test "info code 15: Blocked" do
      option = ExtendedDNSError.new({15, "Query blocked by policy"})
      assert elem(option.data, 0) == 15
    end

    test "info code 16: Censored" do
      option = ExtendedDNSError.new({16, "Query censored"})
      assert elem(option.data, 0) == 16
    end

    test "info code 17: Filtered" do
      option = ExtendedDNSError.new({17, "Query filtered"})
      assert elem(option.data, 0) == 17
    end

    test "info code 18: Prohibited" do
      option = ExtendedDNSError.new({18, "Query prohibited"})
      assert elem(option.data, 0) == 18
    end

    test "info code 19: Stale NXDomain Answer" do
      option = ExtendedDNSError.new({19, "Stale NXDOMAIN"})
      assert elem(option.data, 0) == 19
    end

    test "info code 20: Not Authoritative" do
      option = ExtendedDNSError.new({20, "Not authoritative for zone"})
      assert elem(option.data, 0) == 20
    end

    test "info code 21: Not Supported" do
      option = ExtendedDNSError.new({21, "Feature not supported"})
      assert elem(option.data, 0) == 21
    end

    test "info code 22: No Reachable Authority" do
      option = ExtendedDNSError.new({22, "Cannot reach authority"})
      assert elem(option.data, 0) == 22
    end

    test "info code 23: Network Error" do
      option = ExtendedDNSError.new({23, "Network unreachable"})
      assert elem(option.data, 0) == 23
    end

    test "info code 24: Invalid Data" do
      option = ExtendedDNSError.new({24, "Malformed response"})
      assert elem(option.data, 0) == 24
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = ExtendedDNSError.new({1, "error"})
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles boundary info codes" do
      option = ExtendedDNSError.new({0, "min"})
      assert elem(option.data, 0) == 0

      option = ExtendedDNSError.new({65535, "max"})
      assert elem(option.data, 0) == 65535
    end

    test "handles binary extra text" do
      # Binary data that could contain any bytes
      binary_text = <<1, 2, 3, 4, 5>>
      option = ExtendedDNSError.new({1, binary_text})
      assert elem(option.data, 1) == binary_text
    end

    test "handles very long extra text" do
      long_text = String.duplicate("A", 1000)
      option = ExtendedDNSError.new({1, long_text})
      assert option.length == 2 + 1000
    end

    test "preserves extra text encoding" do
      # Ensure bytes are preserved exactly
      text = "Test\x00Null"
      option = ExtendedDNSError.new({1, text})
      assert elem(option.data, 1) == text
    end
  end
end
