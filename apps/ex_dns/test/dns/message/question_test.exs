defmodule DNS.Message.QuestionTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Question.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/3 for creating questions
  - from_iodata/1 and from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 1035 Section 4.1.2)
  - Question list handling
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Question

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Question)
    end

    test "exports new/3" do
      Code.ensure_loaded!(Question)
      assert Kernel.function_exported?(Question, :new, 3)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Question)
      assert Kernel.function_exported?(Question, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(Question)
      assert Kernel.function_exported?(Question, :from_iodata, 2)
    end

    test "exports list_to_iodata/1" do
      Code.ensure_loaded!(Question)
      assert Kernel.function_exported?(Question, :list_to_iodata, 1)
    end

    test "exports list_from_message/1" do
      Code.ensure_loaded!(Question)
      assert Kernel.function_exported?(Question, :list_from_message, 1)
    end

    test "exports list_from_message/2" do
      Code.ensure_loaded!(Question)
      assert Kernel.function_exported?(Question, :list_from_message, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Question)
      assert is_struct(Question.__struct__())
    end
  end

  describe "struct fields" do
    test "has name field" do
      question = %Question{}
      assert Map.has_key?(question, :name)
    end

    test "has type field" do
      question = %Question{}
      assert Map.has_key?(question, :type)
    end

    test "has class field" do
      question = %Question{}
      assert Map.has_key?(question, :class)
    end

    test "default name is root domain" do
      question = %Question{}
      assert question.name.value == "."
    end

    test "default type is A (1)" do
      question = %Question{}
      assert question.type.value == <<1::16>>
    end

    test "default class is IN (1)" do
      question = %Question{}
      assert question.class.value == <<1::16>>
    end
  end

  describe "new/3" do
    test "creates question with string name, integers" do
      question = Question.new("example.com", 1, 1)
      assert %Question{} = question
    end

    test "creates question with domain name" do
      question = Question.new("www.example.com", 1, 1)
      assert question.name.value == "www.example.com."
    end

    test "creates A record question" do
      question = Question.new("example.com", 1, 1)
      assert question.type.value == <<1::16>>
    end

    test "creates AAAA record question" do
      question = Question.new("example.com", 28, 1)
      assert question.type.value == <<28::16>>
    end

    test "creates question with IN class" do
      question = Question.new("example.com", 1, 1)
      assert question.class.value == <<1::16>>
    end

    test "creates question with atom type" do
      question = Question.new("example.com", :a, 1)
      assert question.type.value == <<1::16>>
    end

    test "creates question with atom class" do
      question = Question.new("example.com", 1, :in)
      assert question.class.value == <<1::16>>
    end

    test "creates question with both atoms" do
      question = Question.new("www.example.com", :a, :in)
      assert question.type.value == <<1::16>>
      assert question.class.value == <<1::16>>
    end

    test "creates MX question" do
      question = Question.new("example.com", :mx, :in)
      assert question.type.value == <<15::16>>
    end

    test "creates PTR question" do
      question = Question.new("1.0.168.192.in-addr.arpa", :ptr, :in)
      assert question.type.value == <<12::16>>
    end

    test "creates SOA question" do
      question = Question.new("example.com", :soa, :in)
      assert question.type.value == <<6::16>>
    end

    test "creates NS question" do
      question = Question.new("example.com", :ns, :in)
      assert question.type.value == <<2::16>>
    end

    test "creates TXT question" do
      question = Question.new("example.com", :txt, :in)
      assert question.type.value == <<16::16>>
    end

    test "creates SRV question" do
      question = Question.new("_http._tcp.example.com", :srv, :in)
      assert question.type.value == <<33::16>>
    end
  end

  describe "from_iodata/1" do
    test "parses question from binary" do
      binary = <<7, "example", 3, "com", 0, 0, 1, 0, 1>>
      question = Question.from_iodata(binary)
      assert %Question{} = question
    end

    test "parses domain name correctly" do
      binary = <<7, "example", 3, "com", 0, 0, 1, 0, 1>>
      question = Question.from_iodata(binary)
      assert question.name.value == "example.com."
    end

    test "parses type correctly" do
      binary = <<7, "example", 3, "com", 0, 0, 1, 0, 1>>
      question = Question.from_iodata(binary)
      assert question.type.value == <<1::16>>
    end

    test "parses class correctly" do
      binary = <<7, "example", 3, "com", 0, 0, 1, 0, 1>>
      question = Question.from_iodata(binary)
      assert question.class.value == <<1::16>>
    end

    test "parses AAAA question" do
      binary = <<7, "example", 3, "com", 0, 0, 28, 0, 1>>
      question = Question.from_iodata(binary)
      assert question.type.value == <<28::16>>
    end

    test "parses subdomain question" do
      binary = <<3, "www", 7, "example", 3, "com", 0, 0, 1, 0, 1>>
      question = Question.from_iodata(binary)
      assert question.name.value == "www.example.com."
    end

    test "parses root domain question" do
      binary = <<0, 0, 6, 0, 1>>
      question = Question.from_iodata(binary)
      assert question.name.value == "."
      assert question.type.value == <<6::16>>
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      question = Question.new("example.com", 1, 1)
      iodata = DNS.to_iodata(question)
      assert iodata == <<7, "example", 3, "com", 0, 0, 1, 0, 1>>
    end

    test "produces correct wire format for subdomain" do
      question = Question.new("www.example.com", 1, 1)
      iodata = DNS.to_iodata(question)
      assert iodata == <<3, "www", 7, "example", 3, "com", 0, 0, 1, 0, 1>>
    end

    test "produces correct wire format for AAAA" do
      question = Question.new("example.com", 28, 1)
      iodata = DNS.to_iodata(question)
      assert iodata == <<7, "example", 3, "com", 0, 0, 28, 0, 1>>
    end

    test "wire format includes type as 16-bit value" do
      question = Question.new("test.com", 255, 1)
      iodata = DNS.to_iodata(question)
      # Extract type from wire format
      domain_size = 10
      <<_domain::binary-size(domain_size), type::16, _::binary>> = iodata
      assert type == 255
    end

    test "wire format includes class as 16-bit value" do
      question = Question.new("test.com", 1, 3)
      iodata = DNS.to_iodata(question)
      # Extract class from wire format
      domain_size = 10
      <<_domain::binary-size(domain_size), _type::16, class::16>> = iodata
      assert class == 3
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'name type class'" do
      question = Question.new("www.example.com", :a, :in)
      assert to_string(question) == "www.example.com. A IN"
    end

    test "includes domain name" do
      question = Question.new("example.com", 1, 1)
      str = to_string(question)
      assert str =~ "example.com."
    end

    test "includes type name" do
      question = Question.new("example.com", 1, 1)
      str = to_string(question)
      assert str =~ "A"
    end

    test "includes class name" do
      question = Question.new("example.com", 1, 1)
      str = to_string(question)
      assert str =~ "IN"
    end

    test "formats AAAA question" do
      question = Question.new("example.com", :aaaa, :in)
      str = to_string(question)
      assert str =~ "AAAA"
    end

    test "string interpolation works" do
      question = Question.new("example.com", :a, :in)
      result = "Query: #{question}"
      assert result =~ "example.com."
      assert result =~ "A"
    end
  end

  describe "list_to_iodata/1" do
    test "converts empty list" do
      iodata = Question.list_to_iodata([])
      assert iodata == <<>>
    end

    test "converts single question" do
      question = Question.new("example.com", 1, 1)
      iodata = Question.list_to_iodata([question])
      assert iodata == <<7, "example", 3, "com", 0, 0, 1, 0, 1>>
    end

    test "converts multiple questions" do
      q1 = Question.new("example.com", 1, 1)
      q2 = Question.new("test.com", 28, 1)
      iodata = Question.list_to_iodata([q1, q2])

      expected =
        <<7, "example", 3, "com", 0, 0, 1, 0, 1>> <>
          <<4, "test", 3, "com", 0, 0, 28, 0, 1>>

      assert iodata == expected
    end
  end

  describe "round-trip" do
    test "new/3 -> to_iodata -> from_iodata preserves data" do
      original = Question.new("www.example.com", 1, 1)
      iodata = DNS.to_iodata(original)
      parsed = Question.from_iodata(iodata)
      assert parsed.name.value == original.name.value
      assert parsed.type.value == original.type.value
      assert parsed.class.value == original.class.value
    end

    test "round-trip preserves various types" do
      types = [1, 2, 5, 6, 12, 15, 16, 28, 33, 255]

      for type <- types do
        original = Question.new("example.com", type, 1)
        iodata = DNS.to_iodata(original)
        parsed = Question.from_iodata(iodata)
        assert parsed.type.value == original.type.value
      end
    end

    test "round-trip preserves various domains" do
      domains = [
        "example.com",
        "www.example.com",
        "mail.server.example.com",
        "localhost"
      ]

      for domain <- domains do
        original = Question.new(domain, 1, 1)
        iodata = DNS.to_iodata(original)
        parsed = Question.from_iodata(iodata)
        assert parsed.name.value == original.name.value
      end
    end
  end

  describe "common query types" do
    test "A record query" do
      question = Question.new("example.com", :a, :in)
      assert to_string(question.type) == "A"
    end

    test "AAAA record query" do
      question = Question.new("example.com", :aaaa, :in)
      assert to_string(question.type) == "AAAA"
    end

    test "MX record query" do
      question = Question.new("example.com", :mx, :in)
      assert to_string(question.type) == "MX"
    end

    test "NS record query" do
      question = Question.new("example.com", :ns, :in)
      assert to_string(question.type) == "NS"
    end

    test "PTR record query" do
      question = Question.new("1.0.168.192.in-addr.arpa", :ptr, :in)
      assert to_string(question.type) == "PTR"
    end

    test "TXT record query" do
      question = Question.new("example.com", :txt, :in)
      assert to_string(question.type) == "TXT"
    end

    test "SOA record query" do
      question = Question.new("example.com", :soa, :in)
      assert to_string(question.type) == "SOA"
    end

    test "CNAME record query" do
      question = Question.new("www.example.com", :cname, :in)
      assert to_string(question.type) == "CNAME"
    end

    test "SRV record query" do
      question = Question.new("_http._tcp.example.com", :srv, :in)
      assert to_string(question.type) == "SRV"
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      question = Question.new("example.com", 1, 1)
      inspect_output = inspect(question)
      assert is_binary(inspect_output)
    end

    test "handles root domain query" do
      question = Question.new(".", 6, 1)
      assert question.name.value == "."
    end

    test "handles single-label domain" do
      question = Question.new("localhost", 1, 1)
      assert question.name.value == "localhost."
    end

    test "handles long domain name" do
      long_domain = "subdomain.of.a.very.long.domain.name.example.com"
      question = Question.new(long_domain, 1, 1)
      assert question.name.value == "#{long_domain}."
    end

    test "handles ANY query type" do
      question = Question.new("example.com", 255, 1)
      assert to_string(question.type) == "ANY"
    end
  end

  describe "DNS protocol compliance" do
    test "question section format (name + type + class)" do
      question = Question.new("example.com", 1, 1)
      iodata = DNS.to_iodata(question)
      # Name (13 bytes) + Type (2 bytes) + Class (2 bytes) = 17 bytes
      assert byte_size(iodata) == 17
    end

    test "type is 16-bit unsigned integer" do
      question = Question.new("test.com", 65535, 1)
      iodata = DNS.to_iodata(question)
      domain_size = 10
      <<_domain::binary-size(domain_size), type::16, _::binary>> = iodata
      assert type == 65535
    end

    test "class is 16-bit unsigned integer" do
      question = Question.new("test.com", 1, 65535)
      iodata = DNS.to_iodata(question)
      domain_size = 10
      <<_domain::binary-size(domain_size), _type::16, class::16>> = iodata
      assert class == 65535
    end
  end
end
