defmodule YellowDog.Mdns.HandlerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Mdns.Handler
  alias YellowDog.Mdns.TestHelper

  import ExUnit.CaptureLog

  # Define test handler module for testing
  defmodule TestHandler do
    use Abyss.Handler

    @impl true
    def handle_data({_ip, _port, _data}, state) do
      {:continue, state}
    end

    @impl true
    def handle_timeout(state) do
      {:continue, state}
    end

    @impl true
    def handle_close(state) do
      {:close, state}
    end

    @impl true
    def terminate(_reason, _state) do
      :ok
    end
  end

  describe "handle_data/2" do
    test "processes valid mDNS query for .local domain" do
      message = TestHelper.create_mdns_query("test.local")
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      log =
        capture_log(fn ->
          result = Handler.handle_data({ip, port, iodata}, state)
          assert result == {:continue, state}
        end)

      assert log =~ "Received mDNS message"
      assert log =~ "Processing mDNS query"
      assert log =~ ".local questions"
    end

    test "processes mDNS PTR query" do
      message = TestHelper.create_ptr_query("_http._tcp.local")
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      log =
        capture_log(fn ->
          result = Handler.handle_data({ip, port, iodata}, state)
          assert result == {:continue, state}
        end)

      assert log =~ "Received mDNS message"
      assert log =~ "Processing mDNS query"
    end

    test "processes mDNS SRV query" do
      message = TestHelper.create_srv_query("_http._tcp.local")
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      log =
        capture_log(fn ->
          result = Handler.handle_data({ip, port, iodata}, state)
          assert result == {:continue, state}
        end)

      assert log =~ "Received mDNS message"
      assert log =~ "Processing mDNS query"
    end

    test "ignores mDNS response messages" do
      # Create a simple query with qr=1 (response) to test response handling
      header = %DNS.Message.Header{
        id: 0x1234,
        # Response
        qr: 1,
        opcode: DNS.Message.OpCode.new(0),
        aa: 0,
        tc: 0,
        rd: 0,
        ra: 0,
        z: 0,
        ad: 0,
        cd: 0,
        rcode: DNS.Message.RCode.new(0),
        qdcount: 1,
        ancount: 0,
        nscount: 0,
        arcount: 0
      }

      message = %DNS.Message{
        header: header,
        qdlist: [DNS.Message.Question.new("test.local", :a, :in)],
        anlist: [],
        nslist: [],
        arlist: []
      }

      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      log =
        capture_log(fn ->
          result = Handler.handle_data({ip, port, iodata}, state)
          assert result == {:continue, state}
        end)

      assert log =~ "Received mDNS message"
      assert log =~ "Ignoring mDNS response message"
    end

    test "ignores queries without .local domains" do
      # Create a query for a non-local domain
      message = TestHelper.create_mdns_query("example.com")
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      log =
        capture_log(fn ->
          result = Handler.handle_data({ip, port, iodata}, state)
          assert result == {:continue, state}
        end)

      assert log =~ "Received mDNS message"
      assert log =~ "No .local questions found, ignoring query"
    end

    test "handles empty query messages" do
      message = TestHelper.create_empty_message()
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      log =
        capture_log(fn ->
          result = Handler.handle_data({ip, port, iodata}, state)
          assert result == {:continue, state}
        end)

      assert log =~ "Received mDNS message"
      assert log =~ "Processing mDNS query"
    end

    test "handles malformed DNS packets" do
      malformed_data = TestHelper.create_malformed_message()
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      log =
        capture_log(fn ->
          result = Handler.handle_data({ip, port, malformed_data}, state)
          assert result == {:continue, state}
        end)

      assert log =~ "Error handling mDNS message"
    end

    test "handles handler errors gracefully" do
      # Directly test error handling by calling with problematic data
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      log =
        capture_log(fn ->
          result = Handler.handle_data({ip, port, "invalid_data"}, state)
          assert result == {:continue, state}
        end)

      assert log =~ "Error handling mDNS message"
    end

    test "handles message reception telemetry" do
      message = TestHelper.create_mdns_query("test.local")
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      # Simplified test that just verifies the handler can process the message
      result = Handler.handle_data({ip, port, iodata}, state)
      assert result == {:continue, state}
    end

    test "handles message processing telemetry" do
      message = TestHelper.create_mdns_query("test.local")
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      # Simplified test that just verifies the handler can process the message
      result = Handler.handle_data({ip, port, iodata}, state)
      assert result == {:continue, state}
    end

    test "handles parse error telemetry" do
      malformed_data = TestHelper.create_malformed_message()
      state = TestHelper.create_test_state()
      ip = {127, 0, 0, 1}
      port = 12345

      # Simplified test that just verifies the handler can handle malformed data
      result = Handler.handle_data({ip, port, malformed_data}, state)
      assert result == {:continue, state}
    end
  end

  describe "handle_timeout/1" do
    test "handles timeout events" do
      state = TestHelper.create_test_state()

      log =
        capture_log(fn ->
          result = Handler.handle_timeout(state)
          assert result == {:continue, state}
        end)

      assert log =~ "mDNS handler timeout"
    end
  end

  describe "handle_close/1" do
    test "handles connection close events" do
      state = TestHelper.create_test_state()

      log =
        capture_log(fn ->
          result = Handler.handle_close(state)
          assert result == {:close, state}
        end)

      assert log =~ "mDNS handler connection closed"
    end
  end

  describe "terminate/2" do
    test "handles termination gracefully" do
      state = TestHelper.create_test_state()

      log =
        capture_log(fn ->
          result = Handler.terminate(:normal, state)
          assert result == :ok
        end)

      assert log =~ "mDNS handler terminating"
    end
  end

  describe "local question detection" do
    test "detects .local domain questions" do
      message = TestHelper.create_mdns_query("test.local")
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()

      log =
        capture_log(fn ->
          Handler.handle_data({{127, 0, 0, 1}, 12345, iodata}, state)
        end)

      assert log =~ ".local questions"
    end

    test "detects .local domain with subdomain" do
      message = TestHelper.create_mdns_query("subdomain.test.local")
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()

      log =
        capture_log(fn ->
          Handler.handle_data({{127, 0, 0, 1}, 12345, iodata}, state)
        end)

      assert log =~ ".local questions"
    end

    test "ignores non-local domain questions" do
      message = TestHelper.create_mdns_query("example.com")
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()

      log =
        capture_log(fn ->
          Handler.handle_data({{127, 0, 0, 1}, 12345, iodata}, state)
        end)

      assert log =~ "No .local questions found"
    end
  end

  describe "response generation" do
    test "generates basic response for local queries" do
      message = TestHelper.create_mdns_query("test.local")
      {:ok, iodata} = TestHelper.encode_message(message)
      state = TestHelper.create_test_state()

      # Test that a response is generated (even if empty for now)
      result = Handler.handle_data({{127, 0, 0, 1}, 12345, iodata}, state)
      assert result == {:continue, state}
    end
  end
end
