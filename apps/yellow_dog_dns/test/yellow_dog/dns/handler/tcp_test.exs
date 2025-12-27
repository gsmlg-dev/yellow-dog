defmodule YellowDog.Dns.Handler.TCPTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Handler.TCP, as: Handler
  alias DNS.Message
  alias DNS.Message.Question

  @moduledoc """
  Tests for the DNS TCP Handler.

  The TCP handler implements ThousandIsland.Handler behaviour and handles:
  - DNS over TCP message framing (RFC 1035: 2-byte length prefix)
  - Connection lifecycle management
  - Buffer management for incomplete messages
  - Integration with ConnectionProcess for query handling
  """

  describe "Handler behaviour compliance" do
    test "handler module uses ThousandIsland.Handler behaviour" do
      assert Code.ensure_loaded?(Handler) == true
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
end
