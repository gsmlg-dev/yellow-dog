defmodule YellowDog.Dhcpv4.HandlerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv4.Handler
  alias YellowDog.Dhcpv4.{ConflictResolver, LeaseManager, LeaseStorage}

  setup do
    # Initialize lease storage
    LeaseStorage.init()

    # Start LeaseManager before each test
    pool_config = %{
      name: "default",
      range_start: {192, 168, 1, 100},
      range_end: {192, 168, 1, 200},
      subnet_mask: {255, 255, 255, 0},
      gateway: {192, 168, 1, 1},
      dns_servers: [{192, 168, 1, 1}],
      domain_name: "test.local",
      lease_time: 86400,
      static_reservations: %{}
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
        ciaddr: {0, 0, 0, 0},
        yiaddr: {0, 0, 0, 0},
        siaddr: {0, 0, 0, 0},
        giaddr: {0, 0, 0, 0},
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
        ciaddr: {0, 0, 0, 0},
        yiaddr: {0, 0, 0, 0},
        siaddr: {0, 0, 0, 0},
        giaddr: {0, 0, 0, 0},
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

      # Create a real UDP socket for testing
      {:ok, socket} = :gen_udp.open(0, mode: :binary, active: false)
      state = %{socket: socket}

      # Test that the handler processes the message without crashing
      result = Handler.handle_data({client_ip, client_port, data}, state)
      assert result == {:continue, state}

      # Clean up socket
      :gen_udp.close(socket)
    end

    test "handles DHCPREQUEST message" do
      data = TestHelper.create_dhcp_request()
      client_ip = {192, 168, 1, 50}
      client_port = 68

      # Create a real UDP socket for testing
      {:ok, socket} = :gen_udp.open(0, mode: :binary, active: false)
      state = %{socket: socket}

      # Test that the handler processes the message without crashing
      result = Handler.handle_data({client_ip, client_port, data}, state)
      assert result == {:continue, state}

      # Clean up socket
      :gen_udp.close(socket)
    end

    test "handles invalid message gracefully" do
      data = TestHelper.create_invalid_message()
      client_ip = {192, 168, 1, 50}
      client_port = 68

      # Mock state with socket
      state = %{socket: self()}

      # Test that the handler handles errors gracefully
      result = Handler.handle_data({client_ip, client_port, data}, state)
      assert result == {:continue, state}
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

      # Test that the handler handles bootreply gracefully
      result = Handler.handle_data({client_ip, client_port, data}, state)
      assert result == {:continue, state}
    end
  end

  # RFC 2131 §4.3.2: DHCPREQUEST addressed to a different server must be silently
  # discarded (no NAK sent). The test verifies that the :request, :ignored telemetry
  # event fires but the :lease, :rejected event does NOT fire.
  describe "RFC 2131 §4.3.2 — wrong server identifier is silently discarded" do
    setup do
      test_pid = self()
      handler_id = "test-dhcpv4-rfc2131-ignored-#{System.unique_integer()}"
      rejected_id = "test-dhcpv4-rfc2131-rejected-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :dhcpv4, :request, :ignored],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        rejected_id,
        [:yellow_dog, :dhcpv4, :lease, :rejected],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        :telemetry.detach(rejected_id)
      end)

      :ok
    end

    test "DHCPREQUEST with non-matching server identifier is silently dropped" do
      # Build a DHCPREQUEST whose Server Identifier option contains
      # 10.0.0.99 — a different server, not us (pool GW is 192.168.1.1).
      message = %DHCPv4.Message{
        op: 1,
        htype: 1,
        hlen: 6,
        hops: 0,
        xid: 0xDEAD_BEEF,
        secs: 0,
        flags: 0,
        ciaddr: {0, 0, 0, 0},
        yiaddr: {0, 0, 0, 0},
        siaddr: {0, 0, 0, 0},
        giaddr: {0, 0, 0, 0},
        chaddr: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>,
        sname: <<0::size(64 * 8)>>,
        file: <<0::size(128 * 8)>>,
        options: [
          # DHCPREQUEST
          %DHCPv4.Message.Option{type: 53, length: 1, value: <<3>>},
          # Requested IP Address (option 50)
          %DHCPv4.Message.Option{type: 50, length: 4, value: <<192, 168, 1, 150>>},
          # Server Identifier (option 54) — deliberately wrong server
          %DHCPv4.Message.Option{type: 54, length: 4, value: <<10, 0, 0, 99>>},
          %DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}
        ]
      }

      data = DHCP.Parameter.to_iodata(message)
      {:ok, socket} = :gen_udp.open(0, mode: :binary, active: false)
      state = %{socket: socket}

      result = Handler.handle_data({{192, 168, 1, 50}, 68, data}, state)
      assert result == {:continue, state}

      # Silently ignored — telemetry event must fire
      assert_receive {:telemetry, [:yellow_dog, :dhcpv4, :request, :ignored], _, meta}, 500
      assert meta.reason =~ "non-matching server identifier"

      # No NAK — the :lease, :rejected event must NOT fire
      refute_receive {:telemetry, [:yellow_dog, :dhcpv4, :lease, :rejected], _, _}, 200

      :gen_udp.close(socket)
    end
  end

  describe "RFC 2131 §4.4.3 — DHCPRELEASE ciaddr validation" do
    setup do
      test_pid = self()
      released_id = "test-release-#{inspect(self())}"
      ignored_id = "test-release-ignore-#{inspect(self())}"

      :telemetry.attach(
        released_id,
        [:yellow_dog, :dhcpv4, :lease, :released],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        ignored_id,
        [:yellow_dog, :dhcpv4, :lease, :release_ignored],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(released_id)
        :telemetry.detach(ignored_id)
      end)

      :ok
    end

    defp build_release_packet(mac, ciaddr_tuple) do
      {a, b, c, d} = ciaddr_tuple

      message = %DHCPv4.Message{
        op: 1,
        htype: 1,
        hlen: 6,
        hops: 0,
        xid: 0xDEAD_CAFE,
        secs: 0,
        flags: 0,
        ciaddr: {a, b, c, d},
        yiaddr: {0, 0, 0, 0},
        siaddr: {0, 0, 0, 0},
        giaddr: {0, 0, 0, 0},
        chaddr: mac <> <<0::size(10 * 8)>>,
        sname: <<0::size(64 * 8)>>,
        file: <<0::size(128 * 8)>>,
        options: [
          # DHCPRELEASE (type 7)
          %DHCPv4.Message.Option{type: 53, length: 1, value: <<7>>},
          %DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}
        ]
      }

      DHCP.Parameter.to_iodata(message)
    end

    test "RELEASE with matching ciaddr releases the lease" do
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01>>

      # Allocate a lease for this MAC
      {:ok, lease} = LeaseManager.allocate_lease(mac)
      assert lease.ip_address != nil

      data = build_release_packet(mac, lease.ip_address)
      {:ok, socket} = :gen_udp.open(0, mode: :binary, active: false)
      state = %{socket: socket}

      result = Handler.handle_data({{192, 168, 1, 50}, 68, data}, state)
      assert result == {:continue, state}

      # Released telemetry must fire
      assert_receive {:telemetry, [:yellow_dog, :dhcpv4, :lease, :released], _, _}, 500

      # Ignored telemetry must NOT fire
      refute_receive {:telemetry, [:yellow_dog, :dhcpv4, :lease, :release_ignored], _, _}, 200

      :gen_udp.close(socket)
    end

    test "RELEASE with mismatched ciaddr is silently ignored (RFC 2131 §4.4.3)" do
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x02>>

      # Allocate a lease for this MAC
      {:ok, lease} = LeaseManager.allocate_lease(mac)
      assert lease.ip_address != nil

      # Build RELEASE with a different ciaddr
      wrong_ip = {10, 0, 0, 99}
      refute lease.ip_address == wrong_ip

      data = build_release_packet(mac, wrong_ip)
      {:ok, socket} = :gen_udp.open(0, mode: :binary, active: false)
      state = %{socket: socket}

      result = Handler.handle_data({{192, 168, 1, 50}, 68, data}, state)
      assert result == {:continue, state}

      # Ignored telemetry must fire
      assert_receive {:telemetry, [:yellow_dog, :dhcpv4, :lease, :release_ignored], _,
                      %{reason: "ciaddr_mismatch"}},
                     500

      # Released telemetry must NOT fire (lease must still be active)
      refute_receive {:telemetry, [:yellow_dog, :dhcpv4, :lease, :released], _, _}, 200

      # Lease should still be active
      assert {:ok, _} = LeaseManager.get_lease(mac)

      :gen_udp.close(socket)
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

      # Test timeout handling callback
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
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Handler)

      # Test that the handler implements the required callbacks
      assert function_exported?(Handler, :handle_data, 2)
      assert function_exported?(Handler, :handle_error, 2)
      assert function_exported?(Handler, :handle_timeout, 1)
    end
  end

  # Tests in this describe block trigger conflict handling warnings which are expected
  describe "PRD integration - ConflictResolver" do
    setup do
      # Start ConflictResolver for these tests
      {:ok, _resolver} = start_supervised(ConflictResolver)
      :ok
    end

    @tag :capture_log
    test "DECLINE message triggers conflict resolution" do
      # First allocate a lease
      mac = <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01>>
      {:ok, lease} = LeaseManager.allocate_lease(mac, nil, nil, "default")
      declined_ip = lease.ip_address

      # Create a DECLINE message
      decline_data = create_decline_message(mac, declined_ip)
      client_ip = declined_ip
      client_port = 68

      # Create a socket for the handler state
      {:ok, socket} = :gen_udp.open(0, mode: :binary, active: false)
      state = %{socket: socket}

      # Verify IP is not quarantined before decline
      refute ConflictResolver.quarantined?(declined_ip)

      # Handle the decline message
      result = Handler.handle_data({client_ip, client_port, decline_data}, state)
      assert result == {:continue, state}

      # After decline, the IP should be quarantined
      assert ConflictResolver.quarantined?(declined_ip)

      :gen_udp.close(socket)
    end

    @tag :capture_log
    test "conflict stats are incremented on DECLINE" do
      # Start with fresh stats
      initial_stats = ConflictResolver.stats()
      initial_conflicts = initial_stats.total_conflicts

      # Allocate a lease
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      {:ok, lease} = LeaseManager.allocate_lease(mac, nil, nil, "default")
      declined_ip = lease.ip_address

      # Create and send DECLINE
      decline_data = create_decline_message(mac, declined_ip)
      {:ok, socket} = :gen_udp.open(0, mode: :binary, active: false)
      state = %{socket: socket}

      Handler.handle_data({declined_ip, 68, decline_data}, state)

      # Stats should show the conflict
      final_stats = ConflictResolver.stats()
      assert final_stats.total_conflicts == initial_conflicts + 1

      :gen_udp.close(socket)
    end
  end

  # Helper to create a DECLINE message
  defp create_decline_message(mac, ip) do
    {a, b, c, d} = ip

    message = %DHCPv4.Message{
      op: 1,
      htype: 1,
      hlen: 6,
      hops: 0,
      xid: 0xDEC11AE1,
      secs: 0,
      flags: 0,
      ciaddr: {0, 0, 0, 0},
      yiaddr: {0, 0, 0, 0},
      siaddr: {0, 0, 0, 0},
      giaddr: {0, 0, 0, 0},
      chaddr: mac <> <<0::size(10 * 8)>>,
      sname: <<0::size(64 * 8)>>,
      file: <<0::size(128 * 8)>>,
      options: [
        # DHCPDECLINE
        %DHCPv4.Message.Option{type: 53, length: 1, value: <<4>>},
        # Requested IP (the declined address)
        %DHCPv4.Message.Option{type: 50, length: 4, value: <<a, b, c, d>>},
        # End
        %DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}
      ]
    }

    DHCP.Parameter.to_iodata(message)
  end
end
