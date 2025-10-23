defmodule YellowDog.Dhcpv4.HandlerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv4.Handler
  alias YellowDog.Dhcpv4.LeaseManager

  import ExUnit.CaptureLog

  setup do
    # Start LeaseManager before each test
    pool_config = %{
      name: "default",
      range_start: {192, 168, 1, 100},
      range_end: {192, 168, 1, 200},
      subnet_mask: {255, 255, 255, 0},
      gateway: {192, 168, 1, 1},
      dns_servers: [{192, 168, 1, 1}],
      domain_name: "test.local",
      lease_time: 86400
    }

    {:ok, lease_manager} = start_supervised({LeaseManager, pools: [pool_config]})

    on_exit(fn ->
      # Clean up lease manager
      if Process.alive?(lease_manager) do
        Process.exit(lease_manager, :normal)
      end
    end)

    :ok
  end

  # Helper functions for creating DHCP test messages
  defmodule TestHelper do
    def create_dhcp_discover do
      # Create a DHCPDISCOVER message struct directly
      message = %DHCPv4.Message{
        # BOOTREQUEST
        op: 1,
        # Ethernet
        htype: 1,
        # MAC address length
        hlen: 6,
        hops: 0,
        xid: 0x12345678,
        secs: 0,
        # Broadcast flag
        flags: 0x8000,
        ciaddr: 0,
        yiaddr: 0,
        siaddr: 0,
        giaddr: 0,
        chaddr: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>,
        # 64 bytes of zeros
        sname: <<0::size(64 * 8)>>,
        # 128 bytes of zeros
        file: <<0::size(128 * 8)>>,
        options: [
          # DHCPDISCOVER
          %DHCPv4.Message.Option{type: 53, length: 1, value: <<1>>},
          # End
          %DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}
        ]
      }

      DHCP.Parameter.to_iodata(message)
    end

    def create_dhcp_request do
      # Create a DHCPREQUEST message struct directly
      message = %DHCPv4.Message{
        # BOOTREQUEST
        op: 1,
        # Ethernet
        htype: 1,
        # MAC address length
        hlen: 6,
        hops: 0,
        xid: 0x09AB99C8,
        secs: 0,
        flags: 0,
        ciaddr: 0,
        yiaddr: 0,
        siaddr: 0,
        giaddr: 0,
        chaddr: <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>,
        # 64 bytes of zeros
        sname: <<0::size(64 * 8)>>,
        # 128 bytes of zeros
        file: <<0::size(128 * 8)>>,
        options: [
          # DHCPREQUEST
          %DHCPv4.Message.Option{type: 53, length: 1, value: <<3>>},
          # Requested IP
          %DHCPv4.Message.Option{type: 50, length: 4, value: <<10, 100, 10, 85>>},
          # Server ID
          %DHCPv4.Message.Option{type: 54, length: 4, value: <<10, 100, 0, 1>>},
          # End
          %DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}
        ]
      }

      DHCP.Parameter.to_iodata(message)
    end

    def create_invalid_message do
      # Create invalid binary data that will cause parsing errors
      # Invalid DHCP message
      <<0xFF, 0xFF, 0xFF, 0xFF>>
    end
  end

  describe "handle_data/2" do
    test "handles DHCPDISCOVER message" do
      data = TestHelper.create_dhcp_discover()
      client_ip = {192, 168, 1, 50}
      client_port = 68

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler processes the message without crashing
      log =
        capture_log(fn ->
          result = Handler.handle_data({client_ip, client_port, data}, state)
          assert result == {:continue, state}
        end)

      # Should log discovery handling
      assert log =~ "DHCPDISCOVER"
    end

    test "handles DHCPREQUEST message" do
      data = TestHelper.create_dhcp_request()
      client_ip = {192, 168, 1, 50}
      client_port = 68

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler processes the message without crashing
      log =
        capture_log(fn ->
          result = Handler.handle_data({client_ip, client_port, data}, state)
          assert result == {:continue, state}
        end)

      # Should log request handling
      assert log =~ "DHCPREQUEST"
    end

    test "handles invalid message gracefully" do
      data = TestHelper.create_invalid_message()
      client_ip = {192, 168, 1, 50}
      client_port = 68

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler handles errors gracefully
      log =
        capture_log(fn ->
          result = Handler.handle_data({client_ip, client_port, data}, state)
          assert result == {:continue, state}
        end)

      # Should log error handling
      assert log =~ "Error handling DHCPv4 message"
    end

    test "handles bootreply messages (should not happen on server)" do
      # Use raw binary data for bootreply message
      # header (BOOTREPLY)
      data =
        <<
          2,
          1,
          6,
          0,
          0x12,
          0x34,
          0x56,
          0x78,
          0,
          0,
          0,
          0,
          # ciaddr, yiaddr, siaddr, giaddr
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          # chaddr
          0x00,
          0x11,
          0x22,
          0x33,
          0x44,
          0x55,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          # sname
          0::size(64 * 8),
          # file
          0::size(128 * 8),
          # magic cookie
          99,
          130,
          83,
          99,
          # end option
          255
        >>

      client_ip = {192, 168, 1, 50}
      client_port = 68

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler ignores bootreply messages
      log =
        capture_log(fn ->
          result = Handler.handle_data({client_ip, client_port, data}, state)
          assert result == {:continue, state}
        end)

      # Should log error handling (since the message is malformed)
      assert log =~ "Error handling DHCPv4 message"
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

      assert log =~ "DHCPv4 handler error"
    end

    test "handles timeouts" do
      state = %{socket: self()}

      # Test timeout handling callback
      log =
        capture_log(fn ->
          result = Handler.handle_timeout(state)
          assert result == {:continue, state}
        end)

      assert log =~ "DHCPv4 handler timeout"
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
end
