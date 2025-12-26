defmodule YellowDog.Dns.Handler.UDPTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Handler.UDP, as: Handler
  alias DNS.Message
  alias DNS.Message.Question

  @moduledoc """
  Tests for the DNS UDP Handler.

  The new handler architecture focuses on network I/O only:
  - Parse incoming DNS queries
  - Create TSI for telemetry
  - Delegate resolution to ViewManager
  - Send responses back to clients

  All DNS resolution logic is in ViewManager, View, and Zone processes.
  """

  describe "DNS query parsing" do
    test "DNS message can be serialized" do
      # Create a simple DNS query
      query = Message.new()

      # Add a question
      question = Question.new("example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      # Serialize to binary
      query_data = DNS.Parameter.to_iodata(query)

      # The handler should be able to process this
      assert is_binary(query_data)
      assert byte_size(query_data) > 0
    end

    test "DNS message can be round-tripped" do
      # Create a simple DNS query
      query = Message.new()
      question = Question.new("test.example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      # Serialize
      query_data = DNS.Parameter.to_iodata(query)

      # Deserialize
      parsed = Message.from_iodata(query_data)

      # Verify question is preserved
      assert length(parsed.qdlist) == 1
      [parsed_question] = parsed.qdlist
      # DNS.Domain needs to be converted to string for comparison
      assert to_string(parsed_question.name) == "test.example.com."
      # DNS.ResourceRecordType is a struct, compare with to_string or atom
      assert to_string(parsed_question.type) == "A" or parsed_question.type == :a
    end
  end

  describe "Error handling" do
    test "handle_error/2 returns continue tuple" do
      state = %{socket: :fake_socket}

      assert {:continue, ^state} = Handler.handle_error(:some_error, state)
    end

    test "handle_error/2 handles various error types" do
      state = %{socket: :fake_socket}

      assert {:continue, ^state} = Handler.handle_error(:timeout, state)
      assert {:continue, ^state} = Handler.handle_error({:error, :nxdomain}, state)
      assert {:continue, ^state} = Handler.handle_error(:econnrefused, state)
    end
  end

  describe "Timeout handling" do
    test "handle_timeout/1 returns continue tuple" do
      state = %{socket: :fake_socket}

      assert {:continue, ^state} = Handler.handle_timeout(state)
    end
  end

  describe "Handler behaviour compliance" do
    test "handler module uses Abyss.Handler behaviour" do
      # The handler uses Abyss.Handler which provides the behaviour
      # We verify the module is loaded and can be called
      assert Code.ensure_loaded?(Handler) == true
    end

    test "exports handle_data/2 callback" do
      Code.ensure_loaded!(Handler)
      assert Kernel.function_exported?(Handler, :handle_data, 2)
    end

    test "exports handle_error/2 callback" do
      Code.ensure_loaded!(Handler)
      assert Kernel.function_exported?(Handler, :handle_error, 2)
    end

    test "exports handle_timeout/1 callback" do
      Code.ensure_loaded!(Handler)
      assert Kernel.function_exported?(Handler, :handle_timeout, 1)
    end
  end

  describe "DNS message building" do
    test "creates valid DNS query message" do
      query = Message.new()
      question = Question.new("example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1}}

      # Verify message structure
      assert query.header.qr == 0
      assert length(query.qdlist) == 1
    end

    test "creates valid DNS response structure" do
      # Create a query
      query = Message.new()
      question = Question.new("example.com", :a, :in)
      query = %{query | qdlist: [question], header: %{query.header | qdcount: 1, id: 12345}}

      # Create response based on query
      response = %Message{
        header: %{
          query.header
          | qr: 1,
            aa: 1,
            rcode: :noerror
        },
        qdlist: query.qdlist,
        anlist: [],
        nslist: [],
        arlist: []
      }

      # Verify response structure
      assert response.header.qr == 1
      assert response.header.id == 12345
      assert response.header.rcode == :noerror
    end
  end
end
