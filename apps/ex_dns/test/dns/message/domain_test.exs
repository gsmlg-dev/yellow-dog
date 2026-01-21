defmodule DNS.Message.DomainTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Domain.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 and new/2 for creating domains
  - from_iodata/1 and from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars, Inspect)
  - Wire format encoding (RFC 1035 Section 4.1.4)
  - Domain name compression (RFC 1035 Section 4.1.4)
  - Edge cases and boundary conditions
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Domain

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Domain)
    end

    test "exports new/1" do
      Code.ensure_loaded!(Domain)
      assert Kernel.function_exported?(Domain, :new, 1)
    end

    test "exports new/2" do
      Code.ensure_loaded!(Domain)
      assert Kernel.function_exported?(Domain, :new, 2)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Domain)
      assert Kernel.function_exported?(Domain, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(Domain)
      assert Kernel.function_exported?(Domain, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Domain)
      assert is_struct(Domain.__struct__())
    end
  end

  describe "struct fields" do
    test "has value field" do
      domain = %Domain{}
      assert Map.has_key?(domain, :value)
    end

    test "has size field" do
      domain = %Domain{}
      assert Map.has_key?(domain, :size)
    end

    test "default value is root (\".\")" do
      domain = %Domain{}
      assert domain.value == "."
    end

    test "default size is 1" do
      domain = %Domain{}
      assert domain.size == 1
    end
  end

  describe "new/1" do
    test "creates domain from simple name" do
      domain = Domain.new("example.com")
      assert %Domain{} = domain
    end

    test "appends trailing dot if missing" do
      domain = Domain.new("example.com")
      assert domain.value == "example.com."
    end

    test "preserves trailing dot if present" do
      domain = Domain.new("example.com.")
      assert domain.value == "example.com."
    end

    test "creates domain with subdomain" do
      domain = Domain.new("www.example.com")
      assert domain.value == "www.example.com."
    end

    test "creates root domain from empty string" do
      domain = Domain.new("")
      assert domain.value == "."
    end

    test "creates root domain from dot" do
      domain = Domain.new(".")
      assert domain.value == "."
    end

    test "calculates correct size for simple domain" do
      domain = Domain.new("example.com")
      # 7 (example) + 1 (length) + 3 (com) + 1 (length) + 1 (null) = 13
      assert domain.size == 13
    end

    test "calculates correct size for subdomain" do
      domain = Domain.new("www.example.com")
      # 3 (www) + 1 + 7 (example) + 1 + 3 (com) + 1 + 1 = 17
      assert domain.size == 17
    end

    test "calculates correct size for root domain" do
      domain = Domain.new(".")
      assert domain.size == 1
    end

    test "creates domain with single label" do
      domain = Domain.new("localhost")
      assert domain.value == "localhost."
      # 9 + 1 (length) + 1 (null) = 11
      assert domain.size == 11
    end

    test "creates domain with many subdomains" do
      domain = Domain.new("a.b.c.d.example.com")
      assert domain.value == "a.b.c.d.example.com."
    end
  end

  describe "new/2" do
    test "creates domain with explicit size" do
      domain = Domain.new("test.com.", 10)
      assert domain.value == "test.com."
      assert domain.size == 10
    end
  end

  describe "from_iodata/1" do
    test "parses root domain" do
      binary = <<0>>
      domain = Domain.from_iodata(binary)
      assert domain.value == "."
      assert domain.size == 1
    end

    test "parses simple domain" do
      binary = <<7, "example", 3, "com", 0>>
      domain = Domain.from_iodata(binary)
      assert domain.value == "example.com."
    end

    test "parses subdomain" do
      binary = <<3, "www", 7, "example", 3, "com", 0>>
      domain = Domain.from_iodata(binary)
      assert domain.value == "www.example.com."
    end

    test "parses single label domain" do
      binary = <<9, "localhost", 0>>
      domain = Domain.from_iodata(binary)
      assert domain.value == "localhost."
    end

    test "parses domain with short label" do
      binary = <<1, "a", 0>>
      domain = Domain.from_iodata(binary)
      assert domain.value == "a."
    end

    test "returns correct size for parsed domain" do
      binary = <<7, "example", 3, "com", 0>>
      domain = Domain.from_iodata(binary)
      assert domain.size == 13
    end
  end

  describe "from_iodata/2 with compression" do
    test "parses compressed domain pointer" do
      # Message with "example.com" at offset 12
      message = <<0::12*8, 7, "example", 3, "com", 0>>
      # Pointer to offset 12 (0xC00C)
      buffer = <<0xC0, 12>>
      domain = Domain.from_iodata(buffer, message)
      assert domain.value == "example.com."
      assert domain.size == 2
    end

    test "parses partially compressed domain" do
      # Message with "example.com" at offset 12
      message = <<0::12*8, 7, "example", 3, "com", 0>>
      # "www" followed by pointer to "example.com"
      buffer = <<3, "www", 0xC0, 12>>
      domain = Domain.from_iodata(buffer, message)
      assert domain.value == "www.example.com."
      assert domain.size == 6
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format for simple domain" do
      domain = Domain.new("example.com")
      iodata = DNS.Parameter.to_iodata(domain)
      assert iodata == <<7, "example", 3, "com", 0>>
    end

    test "produces correct wire format for subdomain" do
      domain = Domain.new("www.example.com")
      iodata = DNS.Parameter.to_iodata(domain)
      assert iodata == <<3, "www", 7, "example", 3, "com", 0>>
    end

    test "produces correct wire format for root domain" do
      domain = Domain.new(".")
      iodata = DNS.Parameter.to_iodata(domain)
      assert iodata == <<0>>
    end

    test "produces correct wire format for single label" do
      domain = Domain.new("localhost")
      iodata = DNS.Parameter.to_iodata(domain)
      assert iodata == <<9, "localhost", 0>>
    end

    test "label length is encoded as single byte" do
      domain = Domain.new("test.com")
      <<len1, _::binary-size(4), len2, _::binary-size(3), terminator>> =
        DNS.Parameter.to_iodata(domain)

      assert len1 == 4
      assert len2 == 3
      assert terminator == 0
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "returns domain value" do
      domain = Domain.new("example.com")
      assert to_string(domain) == "example.com."
    end

    test "returns root for root domain" do
      domain = Domain.new(".")
      assert to_string(domain) == "."
    end

    test "string interpolation works" do
      domain = Domain.new("www.example.com")
      assert "Domain: #{domain}" == "Domain: www.example.com."
    end
  end

  describe "Inspect protocol" do
    test "formats inspect output correctly" do
      domain = Domain.new("example.com")
      assert inspect(domain) == "#DNS.Domain<example.com.>"
    end

    test "inspect shows root domain" do
      domain = Domain.new(".")
      assert inspect(domain) == "#DNS.Domain<.>"
    end

    test "inspect shows subdomain" do
      domain = Domain.new("www.example.com")
      assert inspect(domain) == "#DNS.Domain<www.example.com.>"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves simple domain" do
      original = Domain.new("example.com")
      iodata = DNS.Parameter.to_iodata(original)
      parsed = Domain.from_iodata(iodata)
      assert parsed.value == original.value
    end

    test "new/1 -> to_iodata -> from_iodata preserves subdomain" do
      original = Domain.new("www.example.com")
      iodata = DNS.Parameter.to_iodata(original)
      parsed = Domain.from_iodata(iodata)
      assert parsed.value == original.value
    end

    test "new/1 -> to_iodata -> from_iodata preserves root" do
      original = Domain.new(".")
      iodata = DNS.Parameter.to_iodata(original)
      parsed = Domain.from_iodata(iodata)
      assert parsed.value == original.value
    end

    test "round-trip preserves various domains" do
      domains = [
        ".",
        "a.",
        "localhost.",
        "example.com.",
        "www.example.com.",
        "mail.server.example.com."
      ]

      for domain_str <- domains do
        original = Domain.new(domain_str)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = Domain.from_iodata(iodata)
        assert parsed.value == original.value, "Round-trip failed for: #{domain_str}"
      end
    end
  end

  describe "common domain patterns" do
    test "handles typical web domain" do
      domain = Domain.new("www.google.com")
      assert domain.value == "www.google.com."
    end

    test "handles mail domain" do
      domain = Domain.new("mail.example.com")
      assert domain.value == "mail.example.com."
    end

    test "handles subdomain of subdomain" do
      domain = Domain.new("api.v2.example.com")
      assert domain.value == "api.v2.example.com."
    end

    test "handles country code TLD" do
      domain = Domain.new("example.co.uk")
      assert domain.value == "example.co.uk."
    end

    test "handles numeric subdomain" do
      domain = Domain.new("192.168.1.1.in-addr.arpa")
      assert domain.value == "192.168.1.1.in-addr.arpa."
    end

    test "handles IPv6 reverse lookup domain" do
      domain = Domain.new("8.b.d.0.1.0.0.2.ip6.arpa")
      assert domain.value == "8.b.d.0.1.0.0.2.ip6.arpa."
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      domain = Domain.new("example.com")
      inspect_output = inspect(domain)
      assert is_binary(inspect_output)
    end

    test "handles domain with dash" do
      domain = Domain.new("my-server.example.com")
      assert domain.value == "my-server.example.com."
    end

    test "handles domain with numbers" do
      domain = Domain.new("server1.example.com")
      assert domain.value == "server1.example.com."
    end

    test "handles long label (max 63 characters)" do
      long_label = String.duplicate("a", 63)
      domain = Domain.new("#{long_label}.com")
      assert domain.value == "#{long_label}.com."
    end

    test "handles maximum depth subdomain" do
      deep_domain = "a.b.c.d.e.f.g.h.i.j.example.com"
      domain = Domain.new(deep_domain)
      assert domain.value == "#{deep_domain}."
    end
  end

  describe "DNS protocol compliance" do
    test "encodes each label with length prefix" do
      domain = Domain.new("www.example.com")
      <<len1, label1::binary-size(3), len2, label2::binary-size(7), len3, label3::binary-size(3),
        terminator>> = DNS.Parameter.to_iodata(domain)

      assert len1 == 3
      assert label1 == "www"
      assert len2 == 7
      assert label2 == "example"
      assert len3 == 3
      assert label3 == "com"
      assert terminator == 0
    end

    test "terminates with null byte" do
      domain = Domain.new("test.com")
      iodata = DNS.Parameter.to_iodata(domain)
      assert :binary.last(iodata) == 0
    end

    test "root domain is single null byte" do
      domain = Domain.new(".")
      assert DNS.Parameter.to_iodata(domain) == <<0>>
    end
  end
end
