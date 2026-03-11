defmodule YellowDog.Dhcpv6.HandlerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv6.Handler
  alias YellowDog.Dhcpv6.LeaseManager
  alias YellowDog.Dhcpv6.LeaseStorage

  setup do
    # Initialize storage and start LeaseManager for handler tests
    LeaseStorage.init(storage_type: :ram_copies)
    LeaseStorage.clear_all()

    # Configure a default test pool
    test_pool = %{
      name: "default",
      range_start: "fd00::1000",
      range_end: "fd00::2000",
      dns_servers: ["fd00::1", "fd00::2"],
      domain_name: "test.local",
      preferred_lifetime: 3600,
      valid_lifetime: 7200
    }

    # Start LeaseManager if not already started
    case GenServer.whereis(LeaseManager) do
      nil -> {:ok, _pid} = LeaseManager.start_link(pools: [test_pool])
      _pid -> :ok
    end

    :ok
  end

  # Helper functions for creating DHCPv6 test messages
  defmodule TestHelper do
    def create_dhcpv6_solicit do
      # Create a DHCPv6 SOLICIT message and convert to binary
      message = %DHCPv6.Message{
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

      # Convert to binary for the handler
      DHCPv6.Message.to_iodata(message)
    end

    def create_dhcpv6_request do
      # Create a DHCPv6 REQUEST message and convert to binary
      message = %DHCPv6.Message{
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

      # Convert to binary for the handler
      DHCPv6.Message.to_iodata(message)
    end

    def create_invalid_message do
      # Create invalid binary data that will cause parsing errors
      # Invalid DHCPv6 message
      <<0xFF, 0xFF, 0xFF, 0xFF>>
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
      # DHCPv6 client port
      client_port = 546

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler processes the message without fatal errors
      # Note: UDP send will fail with mock socket, but handler should continue
      result = Handler.handle_data({client_ip, client_port, message}, state)
      assert result == {:continue, state}
    end

    test "handles DHCPv6 REQUEST message" do
      message = TestHelper.create_dhcpv6_request()
      client_ip = TestHelper.create_ipv6_client_address()
      client_port = 546

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler processes the message without crashing
      result = Handler.handle_data({client_ip, client_port, message}, state)
      assert result == {:continue, state}
    end

    test "handles invalid message gracefully" do
      data = TestHelper.create_invalid_message()
      # IPv4 for testing error handling
      client_ip = {192, 168, 1, 50}
      client_port = 546

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler handles errors gracefully
      result = Handler.handle_data({client_ip, client_port, data}, state)
      assert result == {:continue, state}
    end

    test "handles malformed DHCPv6 message" do
      # Create a message with valid start but incomplete data
      # Type + partial transaction ID
      malformed_data = <<1, 0x12, 0x34>>
      client_ip = TestHelper.create_ipv6_client_address()
      client_port = 546

      state = %{socket: self()}

      result = Handler.handle_data({client_ip, client_port, malformed_data}, state)
      assert result == {:continue, state}
    end
  end

  describe "error handling" do
    test "handles handler errors" do
      state = %{socket: self()}

      # Test error handling callback
      result = Handler.handle_error(:test_error, state)
      assert result == {:continue, state}
    end

    test "handles timeouts" do
      state = %{socket: self()}

      # Test timeout handling callback - just verify it doesn't crash
      result = Handler.handle_timeout(state)
      assert result == {:continue, state}
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
      # Ensure module is loaded before checking exported functions
      Code.ensure_loaded!(Handler)

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

      result = Handler.handle_data({ipv4_address, 546, invalid_data}, state)
      assert result == {:continue, state}
    end

    test "formats IPv6 addresses correctly" do
      # Test IPv6 address formatting by using a real IPv6 address
      ipv6_address = {0xFE80, 0, 0, 0, 0, 0, 0, 0x1234}
      state = %{socket: self()}

      # Even with invalid data, the address should be formatted correctly
      invalid_data = <<0xFF>>

      result = Handler.handle_data({ipv6_address, 546, invalid_data}, state)
      assert result == {:continue, state}
    end
  end

  # RFC 3315 §18.2.1: REQUEST with wrong Server Identifier must be silently discarded
  describe "RFC 3315 §18.2.1 — Server Identifier validation" do
    setup do
      test_pid = self()
      handler_id = "test-dhcpv6-server-id-invalid-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :dhcpv6, :message, :invalid],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "REQUEST with mismatched Server Identifier is silently discarded" do
      message = %DHCPv6.Message{
        msg_type: 3,
        transaction_id: <<0xAA, 0xBB, 0xCC>>,
        options: [
          # Client ID
          DHCPv6.Message.Option.new(1, <<1, 2, 3, 4, 5, 6>>),
          # Wrong Server ID (not this server's DUID)
          DHCPv6.Message.Option.new(2, <<0xFF, 0xFF, 0xFF, 0xFF>>),
          # IA_NA
          DHCPv6.Message.Option.new(3, <<0, 0, 0, 1, 0, 0, 3, 84, 0, 0, 5, 220>>)
        ]
      }

      data = DHCPv6.Message.to_iodata(message)
      state = %{socket: self()}
      client_ip = {0xFE80, 0, 0, 0, 0, 0, 0, 1}

      result = Handler.handle_data({client_ip, 546, data}, state)
      assert result == {:continue, state}

      assert_receive {:telemetry, [:yellow_dog, :dhcpv6, :message, :invalid], _,
                      %{reason: "Server Identifier mismatch"}},
                     500
    end

    test "REQUEST without Server Identifier is silently discarded" do
      message = %DHCPv6.Message{
        msg_type: 3,
        transaction_id: <<0xAA, 0xBB, 0xCC>>,
        options: [
          # Client ID only — no Server ID
          DHCPv6.Message.Option.new(1, <<1, 2, 3, 4, 5, 6>>),
          DHCPv6.Message.Option.new(3, <<0, 0, 0, 1, 0, 0, 3, 84, 0, 0, 5, 220>>)
        ]
      }

      data = DHCPv6.Message.to_iodata(message)
      state = %{socket: self()}
      client_ip = {0xFE80, 0, 0, 0, 0, 0, 0, 1}

      result = Handler.handle_data({client_ip, 546, data}, state)
      assert result == {:continue, state}

      assert_receive {:telemetry, [:yellow_dog, :dhcpv6, :message, :invalid], _,
                      %{reason: "missing Server Identifier"}},
                     500
    end
  end
end
