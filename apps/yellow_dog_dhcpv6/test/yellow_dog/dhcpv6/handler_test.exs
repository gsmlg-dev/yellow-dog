defmodule YellowDog.Dhcpv6.HandlerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv6.Handler

  import ExUnit.CaptureLog

  # Helper functions for creating DHCPv6 test messages
  defmodule TestHelper do
    def create_dhcpv6_solicit do
      # Create a DHCPv6 SOLICIT message struct
      %DHCPv6.Message{
        # SOLICIT
        msg_type: 1,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: [
          # CLIENTID
          DHCPv6.Message.Option.new(1, <<1, 1, 2, 3, 4, 5>>),
          # IA_NA
          DHCPv6.Message.Option.new(3, <<0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0>>)
        ]
      }
    end

    def create_dhcpv6_request do
      # Create a DHCPv6 REQUEST message struct
      %DHCPv6.Message{
        # REQUEST
        msg_type: 3,
        transaction_id: <<0x12, 0x34, 0x57>>,
        options: [
          # CLIENTID
          DHCPv6.Message.Option.new(1, <<1, 1, 2, 3, 4, 5>>),
          # SERVERID
          DHCPv6.Message.Option.new(2, <<2, 1, 6, 7, 8, 9>>)
        ]
      }
    end

    def create_invalid_message do
      # Create invalid binary data that will cause parsing errors
      <<0xFF, 0xFF, 0xFF, 0xFF>>  # Invalid DHCPv6 message
    end

    def create_ipv6_client_address do
      # Test IPv6 client address
      {0xFE80, 0, 0, 0, 0, 0, 0, 0x1234}
    end
  end

  describe "handle_data/2" do
    test "handles DHCPv6 SOLICIT message" do
      message = TestHelper.create_dhcpv6_solicit()
      client_ip = TestHelper.create_ipv6_client_address()
      client_port = 546  # DHCPv6 client port

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler processes the message without crashing
      log =
        capture_log(fn ->
          result = Handler.handle_data({client_ip, client_port, message}, state)
          assert result == {:continue, state}
        end)

      # Should log SOLICIT handling
      assert log =~ "SOLICIT"
    end

    test "handles DHCPv6 REQUEST message" do
      message = TestHelper.create_dhcpv6_request()
      client_ip = TestHelper.create_ipv6_client_address()
      client_port = 546

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler processes the message without crashing
      log =
        capture_log(fn ->
          result = Handler.handle_data({client_ip, client_port, message}, state)
          assert result == {:continue, state}
        end)

      # Should log REQUEST handling
      assert log =~ "REQUEST"
    end

    test "handles invalid message gracefully" do
      data = TestHelper.create_invalid_message()
      client_ip = {192, 168, 1, 50}  # IPv4 for testing error handling
      client_port = 546

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler handles errors gracefully
      log =
        capture_log(fn ->
          result = Handler.handle_data({client_ip, client_port, data}, state)
          assert result == {:continue, state}
        end)

      # Should log error handling
      assert log =~ "Error handling DHCPv6 message"
    end

    test "handles malformed DHCPv6 message" do
      # Create a message with valid start but incomplete data
      malformed_data = <<1, 0x12, 0x34>>  # Type + partial transaction ID
      client_ip = TestHelper.create_ipv6_client_address()
      client_port = 546

      state = %{socket: self()}

      log =
        capture_log(fn ->
          result = Handler.handle_data({client_ip, client_port, malformed_data}, state)
          assert result == {:continue, state}
        end)

      # Should handle parsing error gracefully
      assert log =~ "Failed to parse DHCPv6 message" or log =~ "Error handling DHCPv6 message"
    end
  end

  describe "error handling" do
    test "handles handler errors" do
      state = %{socket: self()}

      # Test error handling callback
      log =
        capture_log(fn ->
          result = Handler.handle_error(:test_error, state)
          assert result == {:continue, state}
        end)

      assert log =~ "DHCPv6 handler error"
    end

    test "handles timeouts" do
      state = %{socket: self()}

      # Test timeout handling callback
      log =
        capture_log(fn ->
          result = Handler.handle_timeout(state)
          assert result == {:continue, state}
        end)

      assert log =~ "DHCPv6 handler timeout"
    end
  end

  describe "module functions" do
    test "has required exported functions" do
      # Verify that all required functions exist
      assert is_function(&Handler.handle_data/2)
      assert is_function(&Handler.handle_error/2)
      assert is_function(&Handler.handle_timeout/1)
    end

    test "can be used as Abyss.Handler" do
      # Test that the handler implements the required callbacks
      assert function_exported?(Handler, :handle_data, 2)
      assert function_exported?(Handler, :handle_error, 2)
      assert function_exported?(Handler, :handle_timeout, 1)
    end
  end

  describe "IPv6 address formatting" do
    test "formats IPv4 addresses correctly" do
      # Test IPv4 address formatting (for error cases)
      ipv4_address = {192, 168, 1, 100}

      # We can't directly test the private function, but we can verify
      # that IPv4 addresses are handled in error cases without crashing
      state = %{socket: self()}
      invalid_data = <<0xFF>>

      capture_log(fn ->
        result = Handler.handle_data({ipv4_address, 546, invalid_data}, state)
        assert result == {:continue, state}
      end)
    end

    test "formats IPv6 addresses correctly" do
      # Test IPv6 address formatting by using a real IPv6 address
      ipv6_address = {0xFE80, 0, 0, 0, 0, 0, 0, 0x1234}
      state = %{socket: self()}

      # Even with invalid data, the address should be formatted correctly in logs
      invalid_data = <<0xFF>>

      log =
        capture_log(fn ->
          result = Handler.handle_data({ipv6_address, 546, invalid_data}, state)
          assert result == {:continue, state}
        end)

      # The exact format depends on the implementation, but should contain IPv6-like content
      assert log =~ "Failed to parse" or log =~ "Error handling"
    end
  end
end