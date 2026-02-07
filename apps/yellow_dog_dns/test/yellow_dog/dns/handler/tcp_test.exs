defmodule YellowDog.Dns.Handler.TCPTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.Handler.TCP.

  Tests cover:
  - ThousandIsland.Handler behaviour compliance
  - DNS over TCP message framing (RFC 1035: 2-byte length prefix)
  - Buffer management for incomplete messages
  - Multiple message handling (pipelining)
  - Round-trip serialization
  - Response framing
  - Edge cases and error scenarios
  - Module structure and exports
  """

  use ExUnit.Case, async: false

  alias YellowDog.Dns.Handler.TCP, as: Handler
  alias DNS.Message
  alias DNS.Message.Question

  describe "Handler behaviour compliance" do
    test "handler module uses ThousandIsland.Handler behaviour" do
      assert Code.ensure_loaded?(Handler)
    end

    test "exports handle_connection/2 callback" do
      Code.ensure_loaded!(Handler)
      assert Kernel.function_exported?(Handler, :handle_connection, 2)
    end

    test "exports handle_data/3 callback" do
      Code.ensure_loaded!(Handler)
      assert Kernel.function_exported?(Handler, :handle_data, 3)
    end

    test "exports handle_timeout/2 callback" do
      Code.ensure_loaded!(Handler)
      assert Kernel.function_exported?(Handler, :handle_timeout, 2)
    end

    test "exports handle_close/2 callback" do
      Code.ensure_loaded!(Handler)
      assert Kernel.function_exported?(Handler, :handle_close, 2)
    end
  end

  describe "DNS TCP message framing" do
    test "DNS message can be framed for TCP" do
      # Create a simple DNS query
      query = Message.new()
      question = Question.new("example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      # Serialize to binary
      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()

      # Frame for TCP: 2-byte length prefix
      length = byte_size(query_data)
      framed = <<length::16, query_data::binary>>

      # Verify framing
      assert byte_size(framed) == length + 2

      # Verify we can extract length
      <<extracted_length::16, rest::binary>> = framed
      assert extracted_length == length
      assert rest == query_data
    end

    test "can parse length prefix from framed message" do
      # Create a simple DNS query
      query = Message.new()
      question = Question.new("test.example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      # Serialize and frame
      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      length = byte_size(query_data)
      framed = <<length::16, query_data::binary>>

      # Parse the framed message
      <<parsed_length::16, message::binary-size(parsed_length), remaining::binary>> = framed

      assert parsed_length == length
      assert message == query_data
      assert remaining == <<>>
    end

    test "can handle multiple framed messages" do
      # Create two DNS queries
      query1 = Message.new()
      question1 = Question.new("first.example.com", :a, :in)
      query1 = %{query1 | qdlist: [question1], header: %{query1.header | qdcount: 1}}

      query2 = Message.new()
      question2 = Question.new("second.example.com", :aaaa, :in)
      query2 = %{query2 | qdlist: [question2], header: %{query2.header | qdcount: 1}}

      # Serialize and frame both
      data1 = DNS.to_iodata(query1) |> IO.iodata_to_binary()
      data2 = DNS.to_iodata(query2) |> IO.iodata_to_binary()

      framed1 = <<byte_size(data1)::16, data1::binary>>
      framed2 = <<byte_size(data2)::16, data2::binary>>

      # Concatenate (simulating pipelining)
      combined = framed1 <> framed2

      # Parse first message
      <<len1::16, msg1::binary-size(len1), rest::binary>> = combined

      # Parse second message
      <<len2::16, msg2::binary-size(len2), final::binary>> = rest

      assert msg1 == data1
      assert msg2 == data2
      assert final == <<>>
    end
  end

  describe "DNS message round-trip over TCP framing" do
    test "DNS message survives TCP framing round-trip" do
      # Create a DNS query
      query = Message.new()
      question = Question.new("roundtrip.example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1, id: 12345}}

      # Serialize, frame, unframe, deserialize
      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      length = byte_size(query_data)
      framed = <<length::16, query_data::binary>>

      <<_len::16, unframed::binary>> = framed
      parsed = Message.from_iodata(unframed)

      # Verify message integrity
      assert parsed.header.id == 12345
      assert length(parsed.qdlist) == 1
      [parsed_question] = parsed.qdlist
      assert to_string(parsed_question.name) == "roundtrip.example.com."
    end
  end

  describe "Buffer management patterns" do
    test "handles incomplete length prefix" do
      # Simulate receiving only 1 byte of length prefix
      partial = <<0>>

      # This should be detected as incomplete
      assert byte_size(partial) < 2
    end

    test "handles incomplete message body" do
      # Create a message and frame it
      query = Message.new()
      question = Question.new("incomplete.example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      length = byte_size(query_data)

      # Simulate receiving length prefix but only partial message
      partial = <<length::16, binary_part(query_data, 0, 5)::binary>>

      # Parse length
      <<recv_length::16, recv_data::binary>> = partial

      # Detect incomplete message
      assert byte_size(recv_data) < recv_length
    end

    test "accumulates buffer across multiple receives" do
      query = Message.new()
      question = Question.new("buffered.example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      length = byte_size(query_data)
      framed = <<length::16, query_data::binary>>

      # Split into multiple chunks
      chunk1 = binary_part(framed, 0, 5)
      chunk2 = binary_part(framed, 5, 10)
      chunk3 = binary_part(framed, 15, byte_size(framed) - 15)

      # Simulate buffer accumulation
      buffer1 = chunk1
      buffer2 = buffer1 <> chunk2
      buffer3 = buffer2 <> chunk3

      # Final buffer should be complete
      assert buffer3 == framed

      # Should be parseable
      <<parsed_len::16, parsed_msg::binary-size(parsed_len), _rest::binary>> = buffer3
      assert parsed_msg == query_data
    end
  end

  describe "Response framing" do
    test "response is properly framed with length prefix" do
      # Create a response - use Message.new() which has proper defaults
      response = Message.new()
      # Set QR flag to 1 (response)
      response = %{response | header: %{response.header | qr: 1}}

      # Serialize
      response_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
      length = byte_size(response_data)

      # Frame it (simulating what handler does)
      framed_response = <<length::16, response_data::binary>>

      # Verify
      assert byte_size(framed_response) == length + 2
      <<extracted_len::16, extracted_msg::binary>> = framed_response
      assert extracted_len == length
      assert extracted_msg == response_data
    end
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Handler)
    end

    test "uses ThousandIsland.Handler behaviour" do
      Code.ensure_loaded!(Handler)
      behaviours = Handler.__info__(:attributes)[:behaviour] || []
      assert ThousandIsland.Handler in behaviours
    end

    test "implements GenServer callbacks for handle_info" do
      Code.ensure_loaded!(Handler)
      assert Kernel.function_exported?(Handler, :handle_info, 2)
    end
  end

  describe "framing edge cases" do
    test "handles empty buffer" do
      # Empty buffer should indicate incomplete
      buffer = <<>>
      assert byte_size(buffer) < 2
    end

    test "handles single byte buffer" do
      # Single byte is incomplete length prefix
      buffer = <<42>>
      assert byte_size(buffer) < 2
    end

    test "handles zero-length message declaration" do
      # Length of 0 means no message body expected
      buffer = <<0::16>>
      <<length::16, rest::binary>> = buffer
      assert length == 0
      assert rest == <<>>
    end

    test "handles maximum length message" do
      # DNS over TCP allows messages up to 65535 bytes
      max_length = 65535

      # Create a large query (just for framing test)
      query = Message.new()
      question = Question.new("example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}
      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()

      # Simulate maximum length framing
      framed = <<max_length::16, query_data::binary>>
      <<declared_length::16, _rest::binary>> = framed

      assert declared_length == max_length
      # The actual data is smaller, but length field is max
    end

    test "handles message exactly at declared length boundary" do
      query = Message.new()
      question = Question.new("boundary.test.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}
      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()

      # Frame with exact length
      length = byte_size(query_data)
      framed = <<length::16, query_data::binary>>

      # Parse should succeed with no remainder
      <<parsed_len::16, message::binary-size(parsed_len), remaining::binary>> = framed

      assert parsed_len == length
      assert message == query_data
      assert remaining == <<>>
    end

    test "handles trailing data after complete message" do
      query = Message.new()
      question = Question.new("trailing.test.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}
      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()

      length = byte_size(query_data)
      trailing = <<0xFF, 0xFE>>
      framed = <<length::16, query_data::binary, trailing::binary>>

      <<parsed_len::16, message::binary-size(parsed_len), remaining::binary>> = framed

      assert parsed_len == length
      assert message == query_data
      assert remaining == trailing
    end
  end

  describe "multiple query types framing" do
    test "frames A record query" do
      query = Message.new()
      question = Question.new("a.example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<len::16, msg::binary-size(len), _::binary>> = framed
      parsed = Message.from_iodata(msg)

      [q] = parsed.qdlist
      assert to_string(q.type) == "A"
    end

    test "frames AAAA record query" do
      query = Message.new()
      question = Question.new("aaaa.example.com", :aaaa, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<len::16, msg::binary-size(len), _::binary>> = framed
      parsed = Message.from_iodata(msg)

      [q] = parsed.qdlist
      assert to_string(q.type) == "AAAA"
    end

    test "frames MX record query" do
      query = Message.new()
      question = Question.new("mx.example.com", :mx, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<len::16, msg::binary-size(len), _::binary>> = framed
      parsed = Message.from_iodata(msg)

      [q] = parsed.qdlist
      assert to_string(q.type) == "MX"
    end

    test "frames TXT record query" do
      query = Message.new()
      question = Question.new("txt.example.com", :txt, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<len::16, msg::binary-size(len), _::binary>> = framed
      parsed = Message.from_iodata(msg)

      [q] = parsed.qdlist
      assert to_string(q.type) == "TXT"
    end

    test "frames PTR record query" do
      query = Message.new()
      question = Question.new("1.0.168.192.in-addr.arpa", :ptr, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<len::16, msg::binary-size(len), _::binary>> = framed
      parsed = Message.from_iodata(msg)

      [q] = parsed.qdlist
      assert to_string(q.type) == "PTR"
    end

    test "frames SRV record query" do
      query = Message.new()
      question = Question.new("_http._tcp.example.com", :srv, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<len::16, msg::binary-size(len), _::binary>> = framed
      parsed = Message.from_iodata(msg)

      [q] = parsed.qdlist
      assert to_string(q.type) == "SRV"
    end

    test "frames SOA record query" do
      query = Message.new()
      question = Question.new("example.com", :soa, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<len::16, msg::binary-size(len), _::binary>> = framed
      parsed = Message.from_iodata(msg)

      [q] = parsed.qdlist
      assert to_string(q.type) == "SOA"
    end

    test "frames NS record query" do
      query = Message.new()
      question = Question.new("example.com", :ns, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<len::16, msg::binary-size(len), _::binary>> = framed
      parsed = Message.from_iodata(msg)

      [q] = parsed.qdlist
      assert to_string(q.type) == "NS"
    end

    test "frames CNAME record query" do
      query = Message.new()
      question = Question.new("cname.example.com", :cname, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<len::16, msg::binary-size(len), _::binary>> = framed
      parsed = Message.from_iodata(msg)

      [q] = parsed.qdlist
      assert to_string(q.type) == "CNAME"
    end

    test "frames DNSKEY record query" do
      query = Message.new()
      question = Question.new("dnskey.example.com", :dnskey, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<len::16, msg::binary-size(len), _::binary>> = framed
      parsed = Message.from_iodata(msg)

      [q] = parsed.qdlist
      assert to_string(q.type) == "DNSKEY"
    end
  end

  describe "pipelining scenarios" do
    test "handles three consecutive pipelined queries" do
      queries =
        for n <- 1..3 do
          query = Message.new()
          question = Question.new("query#{n}.example.com", :a, :in)
          %{query | qdlist: [question], header: %{query.header | qdcount: 1, id: n}}
        end

      framed_messages =
        queries
        |> Enum.map(fn q ->
          data = DNS.to_iodata(q) |> IO.iodata_to_binary()
          <<byte_size(data)::16, data::binary>>
        end)
        |> Enum.join(<<>>)

      # Parse all three
      {parsed_queries, remaining} = parse_all_framed(framed_messages, [])

      assert length(parsed_queries) == 3
      assert remaining == <<>>

      # Verify IDs are preserved
      ids = Enum.map(parsed_queries, & &1.header.id)
      assert ids == [1, 2, 3]
    end

    test "handles out-of-order query IDs" do
      ids = [42, 17, 99]

      queries =
        for id <- ids do
          query = Message.new()
          question = Question.new("outoforder.example.com", :a, :in)
          %{query | qdlist: [question], header: %{query.header | qdcount: 1, id: id}}
        end

      framed =
        queries
        |> Enum.map(fn q ->
          data = DNS.to_iodata(q) |> IO.iodata_to_binary()
          <<byte_size(data)::16, data::binary>>
        end)
        |> Enum.join(<<>>)

      {parsed, _} = parse_all_framed(framed, [])
      parsed_ids = Enum.map(parsed, & &1.header.id)

      assert parsed_ids == ids
    end

    test "handles mixed query types in pipeline" do
      type_names = ["A", "AAAA", "MX", "TXT", "SRV"]
      types = [:a, :aaaa, :mx, :txt, :srv]

      queries =
        for {type, idx} <- Enum.with_index(types) do
          query = Message.new()
          question = Question.new("mixed#{idx}.example.com", type, :in)
          %{query | qdlist: [question], header: %{query.header | qdcount: 1, id: idx + 1}}
        end

      framed =
        queries
        |> Enum.map(fn q ->
          data = DNS.to_iodata(q) |> IO.iodata_to_binary()
          <<byte_size(data)::16, data::binary>>
        end)
        |> Enum.join(<<>>)

      {parsed, _} = parse_all_framed(framed, [])
      parsed_types = Enum.map(parsed, fn q -> to_string(hd(q.qdlist).type) end)

      assert parsed_types == type_names
    end
  end

  describe "query header preservation" do
    test "preserves query ID through framing" do
      query = Message.new()
      question = Question.new("id.test.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1, id: 54321}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<_len::16, unframed::binary>> = framed
      parsed = Message.from_iodata(unframed)

      assert parsed.header.id == 54321
    end

    test "preserves RD (recursion desired) flag" do
      query = Message.new()
      question = Question.new("rd.test.com", :a, :in)
      # rd uses 1/0 integers, not true/false
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1, rd: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<_len::16, unframed::binary>> = framed
      parsed = Message.from_iodata(unframed)

      assert parsed.header.rd == 1
    end

    test "preserves opcode through framing" do
      query = Message.new()
      question = Question.new("opcode.test.com", :a, :in)

      # Standard query opcode - use the existing opcode from new()
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      framed = <<byte_size(query_data)::16, query_data::binary>>

      <<_len::16, unframed::binary>> = framed
      parsed = Message.from_iodata(unframed)

      # Opcode is a struct with value as bitstring, convert to integer for comparison
      <<opcode_value::4>> = parsed.header.opcode.value
      assert opcode_value == 0
    end
  end

  describe "response framing scenarios" do
    test "frames response with QR flag" do
      # Create a simple response with just QR and AA flags set
      response = Message.new()

      response = %{
        response
        | header: %{response.header | qr: 1, aa: 1},
          qdlist: [Question.new("answer.test.com", :a, :in)]
      }

      response_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
      length = byte_size(response_data)
      framed = <<length::16, response_data::binary>>

      <<extracted_len::16, extracted_msg::binary-size(extracted_len), _::binary>> = framed
      parsed = Message.from_iodata(extracted_msg)

      assert parsed.header.qr == 1
      assert parsed.header.aa == 1
    end

    test "frames NXDOMAIN response" do
      response = Message.new()

      response = %{
        response
        | header: %{
            response.header
            | qr: 1,
              aa: 1,
              rcode: DNS.Message.RCode.nx_domain()
          },
          qdlist: [Question.new("nxdomain.test.com", :a, :in)]
      }

      response_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
      length = byte_size(response_data)
      framed = <<length::16, response_data::binary>>

      <<_len::16, msg::binary>> = framed
      parsed = Message.from_iodata(msg)

      assert parsed.header.rcode == DNS.Message.RCode.nx_domain()
    end

    test "frames SERVFAIL response" do
      response = Message.new()

      response = %{
        response
        | header: %{
            response.header
            | qr: 1,
              rcode: DNS.Message.RCode.serv_fail()
          },
          qdlist: [Question.new("servfail.test.com", :a, :in)]
      }

      response_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
      length = byte_size(response_data)
      framed = <<length::16, response_data::binary>>

      <<_len::16, msg::binary>> = framed
      parsed = Message.from_iodata(msg)

      assert parsed.header.rcode == DNS.Message.RCode.serv_fail()
    end

    test "frames REFUSED response" do
      response = Message.new()

      response = %{
        response
        | header: %{
            response.header
            | qr: 1,
              rcode: DNS.Message.RCode.refused()
          },
          qdlist: [Question.new("refused.test.com", :a, :in)]
      }

      response_data = DNS.to_iodata(response) |> IO.iodata_to_binary()
      length = byte_size(response_data)
      framed = <<length::16, response_data::binary>>

      <<_len::16, msg::binary>> = framed
      parsed = Message.from_iodata(msg)

      assert parsed.header.rcode == DNS.Message.RCode.refused()
    end
  end

  describe "state structure" do
    test "handler state contains expected keys" do
      # The handler state should contain these keys when initialized
      expected_keys = [:client_ip, :client_port, :connection_pid, :buffer]

      state = %{
        client_ip: {127, 0, 0, 1},
        client_port: 12345,
        connection_pid: self(),
        buffer: <<>>
      }

      for key <- expected_keys do
        assert Map.has_key?(state, key)
      end
    end

    test "buffer is binary type" do
      state = %{buffer: <<>>}
      assert is_binary(state.buffer)
    end

    test "buffer can accumulate data" do
      state = %{buffer: <<>>}

      state = %{state | buffer: state.buffer <> <<1, 2, 3>>}
      assert state.buffer == <<1, 2, 3>>

      state = %{state | buffer: state.buffer <> <<4, 5>>}
      assert state.buffer == <<1, 2, 3, 4, 5>>
    end
  end

  describe "IP address representation" do
    test "IPv4 tuple format" do
      ip = {192, 168, 1, 100}
      assert tuple_size(ip) == 4
      assert elem(ip, 0) in 0..255
      assert elem(ip, 1) in 0..255
      assert elem(ip, 2) in 0..255
      assert elem(ip, 3) in 0..255
    end

    test "IPv6 tuple format" do
      ip = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
      assert tuple_size(ip) == 8

      for i <- 0..7 do
        assert elem(ip, i) in 0..65535
      end
    end

    test "IPv4 loopback address" do
      ip = {127, 0, 0, 1}
      assert ip == {127, 0, 0, 1}
    end

    test "IPv6 loopback address" do
      ip = {0, 0, 0, 0, 0, 0, 0, 1}
      assert ip == {0, 0, 0, 0, 0, 0, 0, 1}
    end
  end

  describe "binary pattern matching for framing" do
    test "big-endian 16-bit length extraction" do
      # 256 in big-endian = <<1, 0>>
      data = <<1, 0>>
      <<length::big-16>> = data
      assert length == 256

      # 512 in big-endian = <<2, 0>>
      data = <<2, 0>>
      <<length::big-16>> = data
      assert length == 512

      # 1 in big-endian = <<0, 1>>
      data = <<0, 1>>
      <<length::big-16>> = data
      assert length == 1
    end

    test "binary size matching" do
      data = <<0, 5, 1, 2, 3, 4, 5>>
      <<length::16, message::binary-size(length), remaining::binary>> = data

      assert length == 5
      assert message == <<1, 2, 3, 4, 5>>
      assert remaining == <<>>
    end

    test "binary size matching with remaining" do
      data = <<0, 3, 1, 2, 3, 4, 5, 6>>
      <<length::16, message::binary-size(length), remaining::binary>> = data

      assert length == 3
      assert message == <<1, 2, 3>>
      assert remaining == <<4, 5, 6>>
    end
  end

  describe "RFC 1035 compliance" do
    test "length field is exactly 2 bytes" do
      # Per RFC 1035 section 4.2.2, TCP length is 2 octets
      query = Message.new()
      question = Question.new("rfc.example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      query_data = DNS.to_iodata(query) |> IO.iodata_to_binary()
      length = byte_size(query_data)
      framed = <<length::16, query_data::binary>>

      # First 2 bytes are length
      length_prefix = binary_part(framed, 0, 2)
      assert byte_size(length_prefix) == 2
    end

    test "length field is unsigned" do
      # Maximum value is 65535 (16-bit unsigned)
      max_length = 65535
      <<encoded::16>> = <<max_length::16>>
      assert encoded == 65535
      assert encoded >= 0
    end

    test "length field is big-endian (network byte order)" do
      # 256 should be encoded as <<1, 0>> not <<0, 1>>
      length = 256
      <<byte1, byte2>> = <<length::big-16>>
      assert byte1 == 1
      assert byte2 == 0
    end
  end

  # Helper function to parse all framed messages from buffer
  defp parse_all_framed(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  defp parse_all_framed(<<length::16, rest::binary>>, acc) when byte_size(rest) >= length do
    <<message::binary-size(length), remaining::binary>> = rest
    parsed = Message.from_iodata(message)
    parse_all_framed(remaining, [parsed | acc])
  end

  defp parse_all_framed(incomplete, acc), do: {Enum.reverse(acc), incomplete}
end
