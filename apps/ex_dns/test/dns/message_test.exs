defmodule DNS.MessageTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.

  Tests cover:
  - Module structure and exports
  - Message creation (new/0)
  - Binary parsing (from_iodata/1)
  - Header attribute updates
  - Question addition
  - Option management
  - DNS.Parameter protocol implementation
  - String.Chars protocol implementation
  """
  use ExUnit.Case, async: true

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

  test "DNS message query with cookie from_iodata/1" do
    raw =
      <<118, 11, 1, 32, 0, 1, 0, 0, 0, 0, 0, 1, 3, 119, 119, 119, 6, 103, 111, 111, 103, 108, 101,
        3, 99, 111, 109, 0, 0, 1, 0, 1, 0, 0, 41, 4, 208, 0, 0, 0, 0, 0, 12, 0, 10, 0, 8, 210,
        213, 222, 136, 249, 150, 28, 88>>

    msg = Message.from_iodata(raw)

    [qd] = msg.qdlist
    [opt | _] = msg.arlist

    assert to_string(qd.name) == "www.google.com."
    assert to_string(qd.type) == "A"
    assert to_string(qd.class) == "IN"

    assert opt.name == Domain.new(".")
    assert opt.type == RRType.new(41)

    edns0 = DNS.Message.EDNS0.from_iodata(DNS.to_iodata(opt))

    assert edns0.version == 0
    assert edns0.udp_payload == 1232
    assert edns0.do_bit == 0
    assert edns0.extended_rcode == 0
    assert Enum.map(edns0.options, &to_string/1) == ["COOKIE: D2D5DE88F9961C58"]

    # IO.inspect(msg, limit: :infinity)
    # IO.puts("#{to_string(msg)}")
  end

  test "DNS message mdns response from_iodata/1" do
    raw1 =
      <<0, 0, 132, 0, 0, 0, 0, 1, 0, 0, 0, 0, 12, 49, 48, 45, 49, 48, 48, 45, 49, 48, 45, 53, 50,
        5, 108, 111, 99, 97, 108, 0, 0, 1, 128, 1, 0, 0, 14, 16, 0, 4, 10, 100, 10, 52>>

    msg = Message.from_iodata(raw1)

    [an | _rest] = msg.anlist

    assert to_string(an.name) == "10-100-10-52.local."
    assert to_string(an.type) == "A"
    assert to_string(an.class) =~ "IN"

    # IO.inspect(msg, limit: :infinity)
    # IO.puts("#{to_string(msg)}")

    raw2 =
      <<0, 0, 132, 0, 0, 0, 0, 1, 0, 0, 0, 1, 35, 69, 65, 55, 68, 57, 55, 57, 70, 66, 55, 70, 66,
        64, 74, 111, 110, 97, 116, 104, 97, 110, 39, 115, 32, 77, 97, 99, 66, 111, 111, 107, 32,
        80, 114, 111, 5, 95, 114, 97, 111, 112, 4, 95, 116, 99, 112, 5, 108, 111, 99, 97, 108, 0,
        0, 16, 128, 1, 0, 0, 17, 148, 0, 189, 10, 99, 110, 61, 48, 44, 49, 44, 50, 44, 51, 7, 100,
        97, 61, 116, 114, 117, 101, 8, 101, 116, 61, 48, 44, 51, 44, 53, 24, 102, 116, 61, 48,
        120, 52, 65, 55, 70, 67, 70, 68, 53, 44, 48, 120, 66, 56, 49, 55, 52, 70, 68, 69, 8, 115,
        102, 61, 48, 120, 50, 48, 52, 8, 109, 100, 61, 48, 44, 49, 44, 50, 17, 97, 109, 61, 77,
        97, 99, 66, 111, 111, 107, 80, 114, 111, 49, 56, 44, 52, 67, 112, 107, 61, 55, 53, 57, 56,
        97, 55, 56, 100, 98, 99, 100, 97, 54, 102, 52, 97, 57, 97, 48, 97, 97, 48, 57, 100, 102,
        55, 51, 97, 53, 100, 50, 55, 48, 57, 52, 51, 48, 52, 55, 48, 102, 49, 97, 98, 53, 102, 98,
        57, 99, 99, 52, 102, 98, 97, 52, 55, 98, 54, 54, 98, 99, 100, 54, 49, 6, 116, 112, 61, 85,
        68, 80, 8, 118, 110, 61, 54, 53, 53, 51, 55, 10, 118, 115, 61, 56, 52, 53, 46, 53, 46, 49,
        4, 118, 118, 61, 48, 192, 12, 0, 47, 128, 1, 0, 0, 17, 148, 0, 9, 192, 12, 0, 5, 0, 0,
        128, 0, 64>>

    msg = Message.from_iodata(raw2)

    [an1 | _] = msg.anlist
    [an2 | _] = msg.arlist

    assert an1.name == Domain.new("EA7D979FB7FB@Jonathan's MacBook Pro._raop._tcp.local.")
    assert an1.type == RRType.new(16)
    assert an1.class == Class.new(0x8001)
    assert an1.ttl == 4500

    assert an2.name.value ==
             Domain.new("EA7D979FB7FB@Jonathan's MacBook Pro._raop._tcp.local.").value

    assert an2.name.size == 2
    assert an2.type == RRType.new(47)
    assert an2.class == Class.new(0x8001)
    assert an2.ttl == 4500
    assert to_string(an2.data) == "EA7D979FB7FB@Jonathan's MacBook Pro._raop._tcp.local. TXT SRV"

    # IO.puts("#{to_string(msg)}")
  end

  test "DNS message [z.cn] large nslist from_iodata/1" do
    raw =
      <<44, 76, 129, 128, 0, 1, 0, 1, 0, 8, 0, 12, 1, 122, 2, 99, 110, 0, 0, 1, 0, 1, 192, 12, 0,
        1, 0, 1, 0, 0, 1, 213, 0, 4, 54, 222, 60, 252, 192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0, 20,
        3, 110, 115, 50, 10, 97, 109, 122, 110, 100, 110, 115, 45, 99, 110, 3, 110, 101, 116, 0,
        192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0, 17, 3, 110, 115, 49, 10, 97, 109, 122, 110, 100,
        110, 115, 45, 99, 110, 192, 14, 192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0, 20, 3, 110, 115,
        49, 10, 97, 109, 122, 110, 100, 110, 115, 45, 99, 110, 3, 99, 111, 109, 0, 192, 12, 0, 2,
        0, 1, 0, 0, 26, 113, 0, 20, 3, 110, 115, 50, 10, 97, 109, 122, 110, 100, 110, 115, 45, 99,
        110, 3, 98, 105, 122, 0, 192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0, 6, 3, 110, 115, 50, 192,
        86, 192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0, 6, 3, 110, 115, 50, 192, 115, 192, 12, 0, 2, 0,
        1, 0, 0, 26, 113, 0, 6, 3, 110, 115, 49, 192, 54, 192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0,
        6, 3, 110, 115, 49, 192, 147, 192, 82, 0, 1, 0, 1, 0, 0, 4, 96, 0, 4, 156, 154, 67, 10,
        192, 82, 0, 28, 0, 1, 0, 0, 4, 96, 0, 16, 32, 1, 5, 2, 70, 18, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        16, 192, 229, 0, 1, 0, 1, 0, 0, 4, 96, 0, 4, 156, 154, 66, 10, 192, 229, 0, 28, 0, 1, 0,
        0, 4, 96, 0, 16, 38, 16, 0, 161, 16, 21, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 192, 111, 0, 1, 0,
        1, 0, 0, 4, 96, 0, 4, 156, 154, 64, 10, 192, 111, 0, 28, 0, 1, 0, 0, 4, 96, 0, 16, 32, 1,
        5, 2, 243, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 192, 211, 0, 1, 0, 1, 0, 0, 18, 112, 0, 4,
        156, 154, 65, 10, 192, 211, 0, 28, 0, 1, 0, 0, 4, 96, 0, 16, 38, 16, 0, 161, 16, 20, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 16, 192, 175, 0, 1, 0, 1, 0, 0, 4, 96, 0, 4, 204, 74, 120, 1, 192,
        175, 0, 28, 0, 1, 0, 0, 4, 96, 0, 16, 38, 16, 0, 161, 50, 209, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        83, 192, 143, 0, 1, 0, 1, 0, 0, 4, 96, 0, 4, 156, 154, 150, 1, 192, 143, 0, 28, 0, 1, 0,
        0, 4, 96, 0, 16, 38, 16, 0, 161, 49, 209, 0, 0, 0, 0, 0, 0, 0, 0, 0, 83>>

    msg = Message.from_iodata(raw)

    assert msg.header.id == 44 * 256 + 76
    assert msg.header.qdcount == 1
    assert msg.header.ancount == 1
    assert msg.header.nscount == 8
    assert msg.header.arcount == 12

    assert length(msg.anlist) == 1
    assert length(msg.nslist) == 8
    assert length(msg.arlist) == 12
    # IO.puts(msg)
  end

  test "DNS message protocol DNS.to_iodata/1" do
    raw1 =
      <<0, 0, 132, 0, 0, 0, 0, 1, 0, 0, 0, 0, 12, 49, 48, 45, 49, 48, 48, 45, 49, 48, 45, 53, 50,
        5, 108, 111, 99, 97, 108, 0, 0, 1, 128, 1, 0, 0, 14, 16, 0, 4, 10, 100, 10, 52>>

    msg = Message.from_iodata(raw1)

    iodata = DNS.to_iodata(msg)

    assert raw1 == iodata
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Message)
    end

    test "exports new/0" do
      Code.ensure_loaded!(Message)
      assert Kernel.function_exported?(Message, :new, 0)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Message)
      assert Kernel.function_exported?(Message, :from_iodata, 1)
    end

    test "exports update_header_attr/3" do
      Code.ensure_loaded!(Message)
      assert Kernel.function_exported?(Message, :update_header_attr, 3)
    end

    test "exports add_question/2" do
      Code.ensure_loaded!(Message)
      assert Kernel.function_exported?(Message, :add_question, 2)
    end

    test "exports put_option/3" do
      Code.ensure_loaded!(Message)
      assert Kernel.function_exported?(Message, :put_option, 3)
    end

    test "exports get_option/2" do
      Code.ensure_loaded!(Message)
      assert Kernel.function_exported?(Message, :get_option, 2)
    end

    test "exports get_option/3" do
      Code.ensure_loaded!(Message)
      assert Kernel.function_exported?(Message, :get_option, 3)
    end

    test "defines struct with required fields" do
      msg = %Message{}
      assert Map.has_key?(msg, :header)
      assert Map.has_key?(msg, :qdlist)
      assert Map.has_key?(msg, :anlist)
      assert Map.has_key?(msg, :nslist)
      assert Map.has_key?(msg, :arlist)
      assert Map.has_key?(msg, :options)
    end
  end

  describe "new/0" do
    test "creates empty message with default header" do
      msg = Message.new()

      assert %Message{} = msg
      assert %Header{} = msg.header
    end

    test "creates message with empty question list" do
      msg = Message.new()

      assert msg.qdlist == []
    end

    test "creates message with empty answer list" do
      msg = Message.new()

      assert msg.anlist == []
    end

    test "creates message with empty authority list" do
      msg = Message.new()

      assert msg.nslist == []
    end

    test "creates message with empty additional list" do
      msg = Message.new()

      assert msg.arlist == []
    end

    test "creates message with empty options" do
      msg = Message.new()

      assert msg.options == []
    end

    test "header has default counts of zero" do
      msg = Message.new()

      assert msg.header.qdcount == 0
      assert msg.header.ancount == 0
      assert msg.header.nscount == 0
      assert msg.header.arcount == 0
    end
  end

  describe "from_iodata/1 - query parsing" do
    test "parses minimal DNS query" do
      # ID: 0x1234, flags: 0x0100 (RD), QDCOUNT: 1, others: 0
      # Question: example.com A IN
      query =
        <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
          <<7, "example", 3, "com", 0, 0x00, 0x01, 0x00, 0x01>>

      msg = Message.from_iodata(query)

      assert msg.header.id == 0x1234
      assert length(msg.qdlist) == 1
    end

    test "parses header correctly" do
      # Simple query header
      query =
        <<0xAB, 0xCD, 0x85, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
          <<3, "www", 0, 0x00, 0x01, 0x00, 0x01>>

      msg = Message.from_iodata(query)

      assert msg.header.id == 0xABCD
      assert msg.header.qr == 1  # Response flag set
    end

    test "parses question section" do
      query =
        <<0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
          <<4, "test", 3, "org", 0, 0x00, 0x01, 0x00, 0x01>>

      msg = Message.from_iodata(query)

      assert length(msg.qdlist) == 1
      [question] = msg.qdlist
      assert to_string(question.name) =~ "test.org"
    end

    test "parses multiple questions" do
      # Query with 2 questions
      query =
        <<0x00, 0x03, 0x01, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
          <<3, "foo", 0, 0x00, 0x01, 0x00, 0x01>> <>
          <<3, "bar", 0, 0x00, 0x01, 0x00, 0x01>>

      msg = Message.from_iodata(query)

      assert length(msg.qdlist) == 2
    end

    test "parses AAAA query" do
      # AAAA query (type 28)
      query =
        <<0x00, 0x04, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
          <<4, "ipv6", 4, "test", 0, 0x00, 0x1C, 0x00, 0x01>>

      msg = Message.from_iodata(query)

      [question] = msg.qdlist
      # Type 28 = AAAA
      assert question.type.value == <<0, 28>>
    end

    test "parses MX query" do
      # MX query (type 15)
      query =
        <<0x00, 0x05, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
          <<4, "mail", 3, "com", 0, 0x00, 0x0F, 0x00, 0x01>>

      msg = Message.from_iodata(query)

      [question] = msg.qdlist
      # Type 15 = MX
      assert question.type.value == <<0, 15>>
    end
  end

  describe "from_iodata/1 - response parsing" do
    test "parses response with answer section" do
      # Response with 1 answer (A record for test.com -> 1.2.3.4)
      response =
        <<0x00, 0x02, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00>> <>
          # Question
          <<4, "test", 3, "com", 0, 0x00, 0x01, 0x00, 0x01>> <>
          # Answer: pointer to name, type A, class IN, TTL 300, rdlength 4, rdata 1.2.3.4
          <<0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, 1, 2, 3, 4>>

      msg = Message.from_iodata(response)

      assert length(msg.anlist) == 1
    end
  end

  describe "update_header_attr/3" do
    test "updates header id" do
      msg = Message.new()
      updated = Message.update_header_attr(msg, :id, 0x5678)

      assert updated.header.id == 0x5678
    end

    test "updates header qr flag" do
      msg = Message.new()
      updated = Message.update_header_attr(msg, :qr, 1)

      assert updated.header.qr == 1
    end

    test "updates header opcode" do
      msg = Message.new()
      updated = Message.update_header_attr(msg, :opcode, 2)

      assert updated.header.opcode == 2
    end

    test "updates header rcode" do
      msg = Message.new()
      updated = Message.update_header_attr(msg, :rcode, 3)

      assert updated.header.rcode == 3
    end

    test "updates multiple attributes sequentially" do
      msg =
        Message.new()
        |> Message.update_header_attr(:id, 0x1111)
        |> Message.update_header_attr(:qr, 1)
        |> Message.update_header_attr(:aa, 1)

      assert msg.header.id == 0x1111
      assert msg.header.qr == 1
      assert msg.header.aa == 1
    end

    test "preserves other message fields" do
      msg = Message.new() |> Message.put_option(:test, :value)
      updated = Message.update_header_attr(msg, :id, 0xFFFF)

      assert updated.options == [test: :value]
    end
  end

  describe "add_question/2" do
    test "adds question to empty message" do
      msg = Message.new()
      question = make_question("example.com")

      updated = Message.add_question(msg, question)

      assert length(updated.qdlist) == 1
    end

    test "increments qdcount in header" do
      msg = Message.new()
      question = make_question("test.org")

      updated = Message.add_question(msg, question)

      assert updated.header.qdcount == 1
    end

    test "prepends question to list" do
      msg = Message.new()
      q1 = make_question("first.com")
      q2 = make_question("second.com")

      updated =
        msg
        |> Message.add_question(q1)
        |> Message.add_question(q2)

      assert length(updated.qdlist) == 2
      # q2 is prepended, so it's first
      [first, _] = updated.qdlist
      assert to_string(first.name) =~ "second.com"
    end

    test "multiple adds increment qdcount correctly" do
      msg = Message.new()
      q1 = make_question("a.com")
      q2 = make_question("b.com")
      q3 = make_question("c.com")

      updated =
        msg
        |> Message.add_question(q1)
        |> Message.add_question(q2)
        |> Message.add_question(q3)

      assert updated.header.qdcount == 3
    end
  end

  describe "put_option/3" do
    test "adds option to empty options list" do
      msg = Message.new()
      updated = Message.put_option(msg, :key, :value)

      assert updated.options == [key: :value]
    end

    test "replaces existing option" do
      msg = Message.new() |> Message.put_option(:key, :old)
      updated = Message.put_option(msg, :key, :new)

      assert updated.options == [key: :new]
    end

    test "adds multiple options" do
      msg =
        Message.new()
        |> Message.put_option(:a, 1)
        |> Message.put_option(:b, 2)
        |> Message.put_option(:c, 3)

      assert Keyword.get(msg.options, :a) == 1
      assert Keyword.get(msg.options, :b) == 2
      assert Keyword.get(msg.options, :c) == 3
    end

    test "preserves other message fields" do
      msg = Message.new() |> Message.update_header_attr(:id, 0x9999)
      updated = Message.put_option(msg, :test, true)

      assert updated.header.id == 0x9999
    end
  end

  describe "get_option/2 and get_option/3" do
    test "returns option value when present" do
      msg = Message.new() |> Message.put_option(:key, :value)

      assert Message.get_option(msg, :key) == :value
    end

    test "returns nil for missing option" do
      msg = Message.new()

      assert Message.get_option(msg, :missing) == nil
    end

    test "returns default value for missing option" do
      msg = Message.new()

      assert Message.get_option(msg, :missing, :default) == :default
    end

    test "returns value over default when present" do
      msg = Message.new() |> Message.put_option(:key, :actual)

      assert Message.get_option(msg, :key, :default) == :actual
    end
  end

  describe "DNS.Parameter protocol" do
    test "implements DNS.Parameter protocol" do
      msg = Message.new()

      binary = DNS.Parameter.to_iodata(msg)
      assert is_binary(binary)
    end

    test "serializes header" do
      msg = Message.new() |> Message.update_header_attr(:id, 0x1234)

      binary = DNS.Parameter.to_iodata(msg)
      <<id::16, _rest::binary>> = binary

      assert id == 0x1234
    end

    test "serializes questions" do
      msg = Message.new()
      question = make_question("test.com")
      msg = Message.add_question(msg, question)

      binary = DNS.Parameter.to_iodata(msg)

      # Should include the question data
      assert byte_size(binary) > 12  # Header is 12 bytes
    end

    test "empty message serializes to header only" do
      msg = Message.new()

      binary = DNS.Parameter.to_iodata(msg)

      # Header is 12 bytes, empty lists add nothing
      assert byte_size(binary) == 12
    end
  end

  describe "String.Chars protocol" do
    test "implements String.Chars protocol" do
      msg = Message.new()

      string = to_string(msg)
      assert is_binary(string)
    end

    test "includes HEADER SECTION" do
      msg = Message.new()

      string = to_string(msg)
      assert String.contains?(string, "HEADER SECTION")
    end

    test "includes QUESTION SECTION" do
      msg = Message.new()

      string = to_string(msg)
      assert String.contains?(string, "QUESTION SECTION")
    end

    test "includes ANSWER SECTION when answers present" do
      # Create a response with an answer
      query =
        <<0x00, 0x02, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00>> <>
          <<4, "test", 3, "com", 0, 0x00, 0x01, 0x00, 0x01>> <>
          <<0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, 1, 2, 3, 4>>

      msg = Message.from_iodata(query)

      string = to_string(msg)
      assert String.contains?(string, "ANSWER SECTION")
    end

    test "excludes ANSWER SECTION when no answers" do
      msg = Message.new()

      string = to_string(msg)
      refute String.contains?(string, "ANSWER SECTION")
    end

    test "includes questions in output" do
      msg = Message.new()
      question = make_question("example.org")
      msg = Message.add_question(msg, question)

      string = to_string(msg)
      assert String.contains?(string, "example.org")
    end
  end

  describe "round-trip encoding" do
    test "header id preserved" do
      msg =
        Message.new()
        |> Message.update_header_attr(:id, 0xABCD)

      binary = DNS.Parameter.to_iodata(msg)
      <<id::16, _::binary>> = binary

      assert id == 0xABCD
    end
  end

  describe "edge cases" do
    test "handles empty domain name query (root)" do
      # Query for root (.)
      query =
        <<0x00, 0x06, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
          <<0, 0x00, 0x02, 0x00, 0x01>>

      msg = Message.from_iodata(query)

      assert length(msg.qdlist) == 1
    end

    test "handles maximum id value" do
      msg = Message.new() |> Message.update_header_attr(:id, 0xFFFF)

      assert msg.header.id == 0xFFFF
    end

    test "struct defaults work correctly" do
      msg = %Message{}

      assert is_struct(msg.header, Header)
      assert is_list(msg.qdlist)
      assert is_list(msg.anlist)
      assert is_list(msg.nslist)
      assert is_list(msg.arlist)
      assert is_list(msg.options)
    end
  end
end
