defmodule DHCPv4.ClientTest do
  @moduledoc """
  Comprehensive unit tests for DHCPv4.Client module.

  Tests cover:
  - Module structure and exports
  - discover/1 - DHCPDISCOVER message creation
  - request/1 - DHCPREQUEST message creation
  - release/1 - DHCPRELEASE message creation
  - decline/1 - DHCPDECLINE message creation
  - Message structure verification
  - Option handling

  Note: Network-dependent tests (send_message, test_lease_cycle) are skipped
  as they require actual network connectivity.
  """
  use ExUnit.Case, async: true

  alias DHCPv4.Client
  alias DHCPv4.Message

  @sample_mac <<0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Client)
    end

    test "exports discover/1" do
      Code.ensure_loaded!(Client)
      assert Kernel.function_exported?(Client, :discover, 1)
    end

    test "exports request/1" do
      Code.ensure_loaded!(Client)
      assert Kernel.function_exported?(Client, :request, 1)
    end

    test "exports release/1" do
      Code.ensure_loaded!(Client)
      assert Kernel.function_exported?(Client, :release, 1)
    end

    test "exports decline/1" do
      Code.ensure_loaded!(Client)
      assert Kernel.function_exported?(Client, :decline, 1)
    end

    test "exports send_message/1" do
      Code.ensure_loaded!(Client)
      assert Kernel.function_exported?(Client, :send_message, 1)
    end

    test "exports test_lease_cycle/1" do
      Code.ensure_loaded!(Client)
      assert Kernel.function_exported?(Client, :test_lease_cycle, 1)
    end
  end

  describe "discover/1" do
    test "creates DHCPDISCOVER message" do
      message = Client.discover(mac: @sample_mac)

      assert %Message{} = message
      assert message.op == 1  # BOOTREQUEST
    end

    test "sets hardware type to Ethernet (1)" do
      message = Client.discover(mac: @sample_mac)

      assert message.htype == 1
    end

    test "sets hardware length to 6" do
      message = Client.discover(mac: @sample_mac)

      assert message.hlen == 6
    end

    test "includes MAC address in chaddr" do
      message = Client.discover(mac: @sample_mac)

      # chaddr should be 16 bytes with MAC padded
      assert byte_size(message.chaddr) == 16
      assert :binary.part(message.chaddr, 0, 6) == @sample_mac
    end

    test "generates transaction ID when not provided" do
      message = Client.discover(mac: @sample_mac)

      assert is_integer(message.xid) or is_binary(message.xid)
    end

    test "uses provided transaction ID" do
      xid = 12345
      message = Client.discover(mac: @sample_mac, xid: xid)

      assert message.xid == xid
    end

    test "includes DHCP message type option (53)" do
      message = Client.discover(mac: @sample_mac)

      option_53 = Enum.find(message.options, fn opt -> opt.type == 53 end)
      assert option_53 != nil
      assert option_53.value == <<1>>  # DHCPDISCOVER
    end

    test "includes hostname when provided" do
      message = Client.discover(mac: @sample_mac, hostname: "testclient")

      option_12 = Enum.find(message.options, fn opt -> opt.type == 12 end)
      assert option_12 != nil
      assert option_12.value == "testclient"
    end

    test "does not include hostname when not provided" do
      message = Client.discover(mac: @sample_mac)

      option_12 = Enum.find(message.options, fn opt -> opt.type == 12 end)
      assert option_12 == nil
    end

    test "includes requested IP when provided" do
      requested = {192, 168, 1, 100}
      message = Client.discover(mac: @sample_mac, requested_ip: requested)

      option_50 = Enum.find(message.options, fn opt -> opt.type == 50 end)
      assert option_50 != nil
      assert option_50.value == <<192, 168, 1, 100>>
    end

    test "raises when MAC not provided" do
      assert_raise KeyError, fn ->
        Client.discover([])
      end
    end
  end

  describe "request/1" do
    test "creates DHCPREQUEST message" do
      message = Client.request(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        requested_ip: {192, 168, 1, 100}
      )

      assert %Message{} = message
      assert message.op == 1  # BOOTREQUEST
    end

    test "includes DHCP message type option (53) with REQUEST type" do
      message = Client.request(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        requested_ip: {192, 168, 1, 100}
      )

      option_53 = Enum.find(message.options, fn opt -> opt.type == 53 end)
      assert option_53.value == <<3>>  # DHCPREQUEST
    end

    test "includes server identifier option (54)" do
      server_ip = {192, 168, 1, 1}
      message = Client.request(
        mac: @sample_mac,
        server_ip: server_ip,
        requested_ip: {192, 168, 1, 100}
      )

      option_54 = Enum.find(message.options, fn opt -> opt.type == 54 end)
      assert option_54 != nil
      assert option_54.value == <<192, 168, 1, 1>>
    end

    test "includes requested IP option (50)" do
      requested_ip = {192, 168, 1, 100}
      message = Client.request(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        requested_ip: requested_ip
      )

      option_50 = Enum.find(message.options, fn opt -> opt.type == 50 end)
      assert option_50 != nil
      assert option_50.value == <<192, 168, 1, 100>>
    end

    test "raises when MAC not provided" do
      assert_raise KeyError, fn ->
        Client.request(server_ip: {192, 168, 1, 1}, requested_ip: {192, 168, 1, 100})
      end
    end

    test "raises when server_ip not provided" do
      assert_raise KeyError, fn ->
        Client.request(mac: @sample_mac, requested_ip: {192, 168, 1, 100})
      end
    end

    test "raises when requested_ip not provided" do
      assert_raise KeyError, fn ->
        Client.request(mac: @sample_mac, server_ip: {192, 168, 1, 1})
      end
    end
  end

  describe "release/1" do
    test "creates DHCPRELEASE message" do
      message = Client.release(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        leased_ip: {192, 168, 1, 100}
      )

      assert %Message{} = message
      assert message.op == 1  # BOOTREQUEST
    end

    test "includes DHCP message type option (53) with RELEASE type" do
      message = Client.release(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        leased_ip: {192, 168, 1, 100}
      )

      option_53 = Enum.find(message.options, fn opt -> opt.type == 53 end)
      assert option_53.value == <<7>>  # DHCPRELEASE
    end

    test "sets ciaddr to leased IP" do
      leased_ip = {192, 168, 1, 100}
      message = Client.release(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        leased_ip: leased_ip
      )

      assert message.ciaddr == leased_ip
    end

    test "includes server identifier option (54)" do
      server_ip = {192, 168, 1, 1}
      message = Client.release(
        mac: @sample_mac,
        server_ip: server_ip,
        leased_ip: {192, 168, 1, 100}
      )

      option_54 = Enum.find(message.options, fn opt -> opt.type == 54 end)
      assert option_54 != nil
      assert option_54.value == <<192, 168, 1, 1>>
    end

    test "raises when required options missing" do
      assert_raise KeyError, fn ->
        Client.release(mac: @sample_mac, server_ip: {192, 168, 1, 1})
      end
    end
  end

  describe "decline/1" do
    test "creates DHCPDECLINE message" do
      message = Client.decline(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        declined_ip: {192, 168, 1, 100}
      )

      assert %Message{} = message
      assert message.op == 1  # BOOTREQUEST
    end

    test "includes DHCP message type option (53) with DECLINE type" do
      message = Client.decline(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        declined_ip: {192, 168, 1, 100}
      )

      option_53 = Enum.find(message.options, fn opt -> opt.type == 53 end)
      assert option_53.value == <<4>>  # DHCPDECLINE
    end

    test "includes server identifier option (54)" do
      server_ip = {192, 168, 1, 1}
      message = Client.decline(
        mac: @sample_mac,
        server_ip: server_ip,
        declined_ip: {192, 168, 1, 100}
      )

      option_54 = Enum.find(message.options, fn opt -> opt.type == 54 end)
      assert option_54 != nil
      assert option_54.value == <<192, 168, 1, 1>>
    end

    test "includes requested/declined IP option (50)" do
      declined_ip = {192, 168, 1, 100}
      message = Client.decline(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        declined_ip: declined_ip
      )

      option_50 = Enum.find(message.options, fn opt -> opt.type == 50 end)
      assert option_50 != nil
      assert option_50.value == <<192, 168, 1, 100>>
    end

    test "raises when required options missing" do
      assert_raise KeyError, fn ->
        Client.decline(mac: @sample_mac, server_ip: {192, 168, 1, 1})
      end
    end
  end

  describe "message structure" do
    test "all messages have hardware type 1 (Ethernet)" do
      discover = Client.discover(mac: @sample_mac)
      request = Client.request(mac: @sample_mac, server_ip: {1, 1, 1, 1}, requested_ip: {1, 1, 1, 2})
      release = Client.release(mac: @sample_mac, server_ip: {1, 1, 1, 1}, leased_ip: {1, 1, 1, 2})
      decline = Client.decline(mac: @sample_mac, server_ip: {1, 1, 1, 1}, declined_ip: {1, 1, 1, 2})

      assert discover.htype == 1
      assert request.htype == 1
      assert release.htype == 1
      assert decline.htype == 1
    end

    test "all messages have hardware length 6" do
      discover = Client.discover(mac: @sample_mac)
      request = Client.request(mac: @sample_mac, server_ip: {1, 1, 1, 1}, requested_ip: {1, 1, 1, 2})

      assert discover.hlen == 6
      assert request.hlen == 6
    end

    test "chaddr is padded to 16 bytes" do
      # 6-byte MAC
      message = Client.discover(mac: @sample_mac)
      assert byte_size(message.chaddr) == 16

      # Short MAC (unusual but handled)
      short_mac = <<0x00, 0x11, 0x22>>
      message2 = Client.discover(mac: short_mac)
      assert byte_size(message2.chaddr) == 16
    end

    test "messages are serializable" do
      message = Client.discover(mac: @sample_mac)

      # Should not raise when converting to binary
      binary = DHCP.to_iodata(message)
      assert is_binary(binary)
    end
  end

  describe "transaction ID handling" do
    test "each message gets unique xid when not specified" do
      msg1 = Client.discover(mac: @sample_mac)
      msg2 = Client.discover(mac: @sample_mac)

      # XIDs should be different (statistically)
      assert msg1.xid != msg2.xid
    end

    test "same xid can be reused across message types" do
      xid = 99999
      discover = Client.discover(mac: @sample_mac, xid: xid)
      request = Client.request(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        requested_ip: {192, 168, 1, 100},
        xid: xid
      )

      assert discover.xid == xid
      assert request.xid == xid
    end
  end

  describe "send_message/1" do
    @tag :skip
    @tag :integration
    test "requires network connectivity" do
      # This test is skipped as it requires actual network
      message = Client.discover(mac: @sample_mac)
      result = Client.send_message(message: message)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "test_lease_cycle/1" do
    @tag :skip
    @tag :integration
    test "requires DHCP server and network" do
      # This test is skipped as it requires actual DHCP server
      result = Client.test_lease_cycle(mac: @sample_mac)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "edge cases" do
    test "handles 6-byte MAC exactly" do
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      message = Client.discover(mac: mac)

      assert :binary.part(message.chaddr, 0, 6) == mac
    end

    test "handles short MAC with padding" do
      short_mac = <<0x00, 0x11, 0x22>>
      message = Client.discover(mac: short_mac)

      # Should be padded
      assert byte_size(message.chaddr) == 16
    end

    test "discover with all optional parameters" do
      message = Client.discover(
        mac: @sample_mac,
        hostname: "myhost",
        requested_ip: {10, 0, 0, 50},
        xid: 12345
      )

      assert message.xid == 12345

      option_12 = Enum.find(message.options, fn opt -> opt.type == 12 end)
      assert option_12.value == "myhost"

      option_50 = Enum.find(message.options, fn opt -> opt.type == 50 end)
      assert option_50.value == <<10, 0, 0, 50>>
    end

    test "messages can be converted to binary for transmission" do
      discover = Client.discover(mac: @sample_mac)
      request = Client.request(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        requested_ip: {192, 168, 1, 100}
      )
      release = Client.release(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        leased_ip: {192, 168, 1, 100}
      )
      decline = Client.decline(
        mac: @sample_mac,
        server_ip: {192, 168, 1, 1},
        declined_ip: {192, 168, 1, 100}
      )

      assert is_binary(DHCP.to_iodata(discover))
      assert is_binary(DHCP.to_iodata(request))
      assert is_binary(DHCP.to_iodata(release))
      assert is_binary(DHCP.to_iodata(decline))
    end
  end
end
