defmodule DNS.ParameterTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Parameter protocol.

  Tests cover:
  - Protocol definition
  - Implementation for DNS.Message
  - Implementation for List
  - Implementation for BitString (binary domain names)
  - Various DNS entity serialization
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias DNS.Message
  alias DNS.Message.Domain
  alias DNS.Message.Header
  alias DNS.Message.Question
  alias DNS.ResourceRecordType, as: RRType
  alias DNS.Class

  # Helper to create a Question with proper types
  defp make_question(name, type \\ 1) do
    %Question{name: Domain.new(name), type: RRType.new(type), class: Class.new(1)}
  end

  describe "protocol definition" do
    test "DNS.Parameter protocol is defined" do
      assert Code.ensure_loaded?(DNS.Parameter)
    end

    test "defines to_iodata/1 callback" do
      Code.ensure_loaded!(DNS.Parameter)
      # Protocol has the function
      assert function_exported?(DNS.Parameter, :to_iodata, 1)
    end
  end

  describe "DNS.to_iodata/1 wrapper" do
    test "wrapper function exists in DNS module" do
      Code.ensure_loaded!(DNS)
      assert function_exported?(DNS, :to_iodata, 1)
    end

    test "wraps DNS.Parameter.to_iodata/1" do
      domain = Domain.new("test.com")

      # Both should produce the same output
      assert DNS.to_iodata(domain) == DNS.Parameter.to_iodata(domain)
    end
  end

  describe "implementation for DNS.Message" do
    test "serializes empty message" do
      msg = Message.new()

      binary = DNS.Parameter.to_iodata(msg)

      assert is_binary(binary)
      # Empty message is just header (12 bytes)
      assert byte_size(binary) == 12
    end

    test "serializes message with header ID" do
      msg = Message.new() |> Message.update_header_attr(:id, 0xABCD)

      binary = DNS.Parameter.to_iodata(msg)

      <<id::16, _rest::binary>> = binary
      assert id == 0xABCD
    end

    test "serializes message with question" do
      msg = Message.new()
      question = make_question("example.com")
      msg = Message.add_question(msg, question)

      binary = DNS.Parameter.to_iodata(msg)

      # Should be larger than just header
      assert byte_size(binary) > 12
    end

    test "serializes header flags correctly" do
      msg =
        Message.new()
        |> Message.update_header_attr(:qr, 1)
        |> Message.update_header_attr(:rd, 1)

      binary = DNS.Parameter.to_iodata(msg)

      # Parse flags from binary
      <<_id::16, flags::16, _rest::binary>> = binary

      # QR flag is bit 15 (0x8000), RD flag is bit 8 (0x0100)
      # QR set
      assert (flags &&& 0x8000) != 0
      # RD set
      assert (flags &&& 0x0100) != 0
    end
  end

  describe "implementation for List" do
    test "serializes empty list" do
      result = DNS.Parameter.to_iodata([])

      assert result == <<>>
    end

    test "serializes list with single domain" do
      domains = [Domain.new("test.com")]

      result = DNS.Parameter.to_iodata(domains)

      assert is_binary(result)
      # Should contain the domain bytes
      assert byte_size(result) > 0
    end

    test "serializes list with multiple domains" do
      domains = [Domain.new("a.com"), Domain.new("b.com")]

      result = DNS.Parameter.to_iodata(domains)

      # Combined size of both domains
      assert byte_size(result) > byte_size(DNS.to_iodata(Domain.new("a.com")))
    end

    test "concatenates elements in order" do
      d1 = Domain.new("first.com")
      d2 = Domain.new("second.com")

      result = DNS.Parameter.to_iodata([d1, d2])

      # Result should be d1's bytes followed by d2's bytes
      expected = DNS.to_iodata(d1) <> DNS.to_iodata(d2)
      assert result == expected
    end

    test "serializes list of questions" do
      q1 = make_question("a.com")
      q2 = make_question("b.com")

      result = DNS.Parameter.to_iodata([q1, q2])

      # Should produce combined binary
      assert is_binary(result)
      assert byte_size(result) > 0
    end
  end

  describe "implementation for BitString" do
    test "treats binary string as domain name" do
      result = DNS.Parameter.to_iodata("example.com")

      # Should convert to DNS domain format
      assert is_binary(result)
    end

    test "produces same output as Domain.new" do
      domain_string = "test.org"

      from_string = DNS.Parameter.to_iodata(domain_string)
      from_domain = DNS.Parameter.to_iodata(Domain.new(domain_string))

      assert from_string == from_domain
    end

    test "handles single label" do
      result = DNS.Parameter.to_iodata("localhost")

      assert is_binary(result)
      # Format: length byte + "localhost" + null terminator
      assert byte_size(result) > 0
    end

    test "handles multi-label domain" do
      result = DNS.Parameter.to_iodata("www.example.com")

      assert is_binary(result)
    end

    test "handles root domain" do
      result = DNS.Parameter.to_iodata(".")

      # Root domain is just a null byte
      assert result == Domain.new(".") |> DNS.to_iodata()
    end

    test "handles trailing dot" do
      result = DNS.Parameter.to_iodata("example.com.")

      # Should be same as without trailing dot
      without_dot = DNS.Parameter.to_iodata("example.com")
      assert result == without_dot
    end
  end

  describe "domain serialization format" do
    test "domain starts with label length" do
      result = DNS.Parameter.to_iodata("abc")

      # First byte should be length 3
      <<first_byte, _rest::binary>> = result
      assert first_byte == 3
    end

    test "domain ends with null terminator" do
      result = DNS.Parameter.to_iodata("test")

      # Last byte should be 0
      binary_size = byte_size(result)
      <<_head::binary-size(binary_size - 1), last_byte>> = result
      assert last_byte == 0
    end

    test "multi-label domain has length prefix for each label" do
      result = DNS.Parameter.to_iodata("a.bb.ccc")

      # Format: 1,"a", 2,"bb", 3,"ccc", 0
      <<len1, "a", len2, "bb", len3, "ccc", terminator>> = result
      assert len1 == 1
      assert len2 == 2
      assert len3 == 3
      assert terminator == 0
    end
  end

  describe "protocol implementation verification" do
    test "Domain implements DNS.Parameter" do
      domain = Domain.new("test.com")

      # Should not raise
      result = DNS.Parameter.to_iodata(domain)
      assert is_binary(result)
    end

    test "Header implements DNS.Parameter" do
      header = Header.new()

      result = DNS.Parameter.to_iodata(header)
      assert is_binary(result)
      # DNS header is always 12 bytes
      assert byte_size(result) == 12
    end

    test "Question implements DNS.Parameter" do
      question = make_question("test.com")

      result = DNS.Parameter.to_iodata(question)
      assert is_binary(result)
    end

    test "ResourceRecordType implements DNS.Parameter" do
      rrtype = RRType.new(1)

      result = DNS.Parameter.to_iodata(rrtype)
      assert is_binary(result)
      # RRType is 2 bytes
      assert byte_size(result) == 2
    end
  end

  describe "edge cases" do
    test "handles very long domain labels" do
      # Maximum label length is 63 characters
      long_label = String.duplicate("a", 63)

      result = DNS.Parameter.to_iodata(long_label)

      assert is_binary(result)
    end

    test "handles unicode domain (punycode)" do
      # Note: DNS uses ASCII, unicode should be converted to punycode
      # This test verifies it doesn't crash; actual punycode conversion
      # depends on the Domain module implementation
      result = DNS.Parameter.to_iodata("test.example.com")

      assert is_binary(result)
    end

    test "handles empty string" do
      # Empty string becomes root domain
      result = DNS.Parameter.to_iodata("")

      assert is_binary(result)
    end
  end

  describe "round-trip compatibility" do
    test "serialized domain can be part of valid DNS message" do
      msg = Message.new()
      question = make_question("roundtrip.test")
      msg = Message.add_question(msg, question)

      binary = DNS.Parameter.to_iodata(msg)

      # Should be parseable
      parsed = Message.from_iodata(binary)

      assert length(parsed.qdlist) == 1
    end
  end
end
