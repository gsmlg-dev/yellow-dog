defmodule YellowDog.Dhcpv4.IntegrationTest do
  @moduledoc """
  Integration tests for the DHCPv4 server using real UDP sockets.

  These tests verify the complete DHCP protocol flow with actual network
  communication.
  """

  use ExUnit.Case, async: false

  alias DHCPv4.Message
  alias DHCPv4.Message.Option
  alias YellowDog.Dhcpv4.{LeaseStorage, Supervisor}

  @moduletag :integration
  @moduletag :privileged_port
  @moduletag timeout: 30_000

  # Test configuration
  @test_port 56767
  @server_ip {127, 0, 0, 1}
  @test_mac <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
  @test_pool_config [
    pools: [
      %{
        "name" => "integration_test",
        "range_start" => {192, 168, 100, 10},
        "range_end" => {192, 168, 100, 50},
        "subnet_mask" => {255, 255, 255, 0},
        "gateway" => {192, 168, 100, 1},
        "dns_servers" => [{8, 8, 8, 8}, {8, 8, 4, 4}],
        "domain_name" => "test.local",
        "lease_time" => 3600
      }
    ]
  ]

  setup_all do
    # Clean up any existing Mnesia leases
    LeaseStorage.init(storage_type: :ram_copies)
    leases = LeaseStorage.list()
    Enum.each(leases, fn lease -> LeaseStorage.delete(lease.mac_address) end)

    # Start the DHCPv4 supervisor on test port
    config = Keyword.put(@test_pool_config, :port, @test_port)
    {:ok, supervisor_pid} = Supervisor.start_link(config)

    # Give server time to start
    Process.sleep(500)

    on_exit(fn ->
      if Process.alive?(supervisor_pid) do
        GenServer.stop(supervisor_pid, :normal)
      end
    end)

    {:ok, %{supervisor: supervisor_pid}}
  end

  setup do
    # Clean up leases between tests
    leases = LeaseStorage.list()
    Enum.each(leases, fn lease -> LeaseStorage.delete(lease.mac_address) end)

    # Create UDP client socket
    {:ok, socket} =
      :gen_udp.open(0, [
        :binary,
        {:active, false},
        {:reuseaddr, true}
      ])

    on_exit(fn ->
      :gen_udp.close(socket)
    end)

    {:ok, %{socket: socket}}
  end

  describe "DHCP DISCOVER" do
    test "server responds with OFFER message", %{socket: socket} do
      # Build DHCP DISCOVER message
      discover = build_discover_message(@test_mac)

      # Send DISCOVER
      :ok = :gen_udp.send(socket, @server_ip, @test_port, discover)

      # Wait for OFFER response
      case :gen_udp.recv(socket, 0, 5000) do
        {:ok, {_ip, _port, response_data}} ->
          # Parse response
          offer = Message.from_iodata(response_data)

          # Verify OFFER
          assert offer.op == 2
          # BOOTREPLY
          assert offer.xid == 0x12345678
          assert offer.chaddr == pad_mac(@test_mac)

          # Verify offered IP is in range
          assert offered_ip = integer_to_ip(offer.yiaddr)
          assert in_test_range?(offered_ip)

          # Verify message type option (should be OFFER = 2)
          message_type = get_option(offer.options, 53)
          assert message_type == <<2>>

        {:error, :timeout} ->
          flunk("Did not receive DHCP OFFER within timeout")
      end
    end

    test "multiple clients receive different IPs", %{socket: socket} do
      # Request IP for first client
      mac1 = <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>
      discover1 = build_discover_message(mac1, xid: 0x11111111)
      :ok = :gen_udp.send(socket, @server_ip, @test_port, discover1)

      {:ok, {_, _, response1}} = :gen_udp.recv(socket, 0, 5000)
      offer1 = Message.from_iodata(response1)
      ip1 = integer_to_ip(offer1.yiaddr)

      # Request IP for second client
      mac2 = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      discover2 = build_discover_message(mac2, xid: 0x22222222)
      :ok = :gen_udp.send(socket, @server_ip, @test_port, discover2)

      {:ok, {_, _, response2}} = :gen_udp.recv(socket, 0, 5000)
      offer2 = Message.from_iodata(response2)
      ip2 = integer_to_ip(offer2.yiaddr)

      # Verify different IPs allocated
      assert ip1 != ip2
      assert in_test_range?(ip1)
      assert in_test_range?(ip2)
    end
  end

  describe "DHCP REQUEST/ACK" do
    test "server responds to REQUEST with ACK", %{socket: socket} do
      # First, get an OFFER
      discover = build_discover_message(@test_mac)
      :ok = :gen_udp.send(socket, @server_ip, @test_port, discover)
      {:ok, {_, _, offer_data}} = :gen_udp.recv(socket, 0, 5000)
      offer = Message.from_iodata(offer_data)

      offered_ip = integer_to_ip(offer.yiaddr)
      server_id = get_option(offer.options, 54)

      # Send REQUEST to accept the offer
      request = build_request_message(@test_mac, offered_ip, server_id)
      :ok = :gen_udp.send(socket, @server_ip, @test_port, request)

      # Wait for ACK
      case :gen_udp.recv(socket, 0, 5000) do
        {:ok, {_, _, ack_data}} ->
          ack = Message.from_iodata(ack_data)

          # Verify ACK
          assert ack.op == 2
          assert ack.xid == 0x12345678
          assert integer_to_ip(ack.yiaddr) == offered_ip

          # Verify message type is ACK (5)
          message_type = get_option(ack.options, 53)
          assert message_type == <<5>>

          # Verify lease was created in storage
          {:ok, lease} = LeaseStorage.get(@test_mac)
          assert lease.ip_address == offered_ip
          assert lease.state == :active

        {:error, :timeout} ->
          flunk("Did not receive DHCP ACK within timeout")
      end
    end

    test "complete DORA flow", %{socket: socket} do
      # DISCOVER
      discover = build_discover_message(@test_mac)
      :ok = :gen_udp.send(socket, @server_ip, @test_port, discover)

      {:ok, {_, _, offer_data}} = :gen_udp.recv(socket, 0, 5000)
      offer = Message.from_iodata(offer_data)

      # Verify OFFER
      message_type = get_option(offer.options, 53)
      assert message_type == <<2>>

      # REQUEST
      offered_ip = integer_to_ip(offer.yiaddr)
      server_id = get_option(offer.options, 54)
      request = build_request_message(@test_mac, offered_ip, server_id)
      :ok = :gen_udp.send(socket, @server_ip, @test_port, request)

      {:ok, {_, _, ack_data}} = :gen_udp.recv(socket, 0, 5000)
      ack = Message.from_iodata(ack_data)

      # Verify ACK
      message_type = get_option(ack.options, 53)
      assert message_type == <<5>>
      assert integer_to_ip(ack.yiaddr) == offered_ip

      # Verify lease in storage
      {:ok, lease} = LeaseStorage.get(@test_mac)
      assert lease.ip_address == offered_ip
      assert lease.state == :active
    end
  end

  describe "DHCP RELEASE" do
    test "server accepts RELEASE and marks lease as released", %{socket: socket} do
      # First, allocate a lease via DORA
      discover = build_discover_message(@test_mac)
      :ok = :gen_udp.send(socket, @server_ip, @test_port, discover)
      {:ok, {_, _, offer_data}} = :gen_udp.recv(socket, 0, 5000)
      offer = Message.from_iodata(offer_data)

      offered_ip = integer_to_ip(offer.yiaddr)
      server_id = get_option(offer.options, 54)

      request = build_request_message(@test_mac, offered_ip, server_id)
      :ok = :gen_udp.send(socket, @server_ip, @test_port, request)
      {:ok, {_, _, _ack_data}} = :gen_udp.recv(socket, 0, 5000)

      # Verify lease is active
      {:ok, lease} = LeaseStorage.get(@test_mac)
      assert lease.state == :active

      # Send RELEASE
      release = build_release_message(@test_mac, offered_ip, server_id)
      :ok = :gen_udp.send(socket, @server_ip, @test_port, release)

      # Wait a bit for processing
      Process.sleep(100)

      # Verify lease is released
      {:ok, lease} = LeaseStorage.get(@test_mac)
      assert lease.state == :released
    end
  end

  # Helper Functions

  defp build_discover_message(mac, opts \\ []) do
    xid = Keyword.get(opts, :xid, 0x12345678)

    message = %Message{
      op: 1,
      # BOOTREQUEST
      htype: 1,
      # Ethernet
      hlen: 6,
      hops: 0,
      xid: xid,
      secs: 0,
      flags: 0x8000,
      # Broadcast flag
      ciaddr: {0, 0, 0, 0},
      yiaddr: {0, 0, 0, 0},
      siaddr: {0, 0, 0, 0},
      giaddr: {0, 0, 0, 0},
      chaddr: pad_mac(mac),
      sname: <<0::8*64>>,
      file: <<0::8*128>>,
      options: [
        # Message Type: DISCOVER
        %Option{type: 53, length: 1, value: <<1>>},
        # Requested IP (optional)
        # Parameter Request List
        %Option{type: 55, length: 4, value: <<1, 3, 6, 15>>},
        # End option
        %Option{type: 255, length: 0, value: <<>>}
      ]
    }

    DHCP.Parameter.to_iodata(message) |> IO.iodata_to_binary()
  end

  defp build_request_message(mac, requested_ip, server_id) do
    message = %Message{
      op: 1,
      htype: 1,
      hlen: 6,
      hops: 0,
      xid: 0x12345678,
      secs: 0,
      flags: 0x8000,
      ciaddr: {0, 0, 0, 0},
      yiaddr: {0, 0, 0, 0},
      siaddr: {0, 0, 0, 0},
      giaddr: {0, 0, 0, 0},
      chaddr: pad_mac(mac),
      sname: <<0::8*64>>,
      file: <<0::8*128>>,
      options: [
        # Message Type: REQUEST
        %Option{type: 53, length: 1, value: <<3>>},
        # Requested IP
        %Option{type: 50, length: 4, value: ip_to_binary(requested_ip)},
        # Server Identifier
        %Option{type: 54, length: 4, value: server_id},
        # End option
        %Option{type: 255, length: 0, value: <<>>}
      ]
    }

    DHCP.Parameter.to_iodata(message) |> IO.iodata_to_binary()
  end

  defp build_release_message(mac, client_ip, server_id) do
    message = %Message{
      op: 1,
      htype: 1,
      hlen: 6,
      hops: 0,
      xid: 0x12345678,
      secs: 0,
      flags: 0,
      ciaddr: client_ip,
      yiaddr: {0, 0, 0, 0},
      siaddr: {0, 0, 0, 0},
      giaddr: {0, 0, 0, 0},
      chaddr: pad_mac(mac),
      sname: <<0::8*64>>,
      file: <<0::8*128>>,
      options: [
        # Message Type: RELEASE
        %Option{type: 53, length: 1, value: <<7>>},
        # Server Identifier
        %Option{type: 54, length: 4, value: server_id},
        # End option
        %Option{type: 255, length: 0, value: <<>>}
      ]
    }

    DHCP.Parameter.to_iodata(message) |> IO.iodata_to_binary()
  end

  defp pad_mac(<<mac::binary-size(6)>>), do: mac <> <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>

  defp get_option(options, type) do
    option = Enum.find(options, fn opt -> opt.type == type end)
    option && option.value
  end

  defp integer_to_ip(int) do
    <<a, b, c, d>> = <<int::32>>
    {a, b, c, d}
  end

  # Unused but kept for potential future use in IP range calculations
  # defp ip_to_integer({a, b, c, d}) do
  #   <<int::32>> = <<a, b, c, d>>
  #   int
  # end

  defp ip_to_binary({a, b, c, d}), do: <<a, b, c, d>>

  defp in_test_range?({192, 168, 100, n}) when n >= 10 and n <= 50, do: true
  defp in_test_range?(_), do: false
end
