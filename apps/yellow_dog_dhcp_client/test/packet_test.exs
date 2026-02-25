defmodule YellowDog.DhcpClient.PacketTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.{Packet, Lease, VendorOptions}
  alias DHCPv4.Message
  alias DHCPv4.Message.Option

  @test_mac <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
  @test_xid 0x12345678

  # ── Helpers ──

  defp parse_built_packet(binary) do
    data = IO.iodata_to_binary(binary)
    Message.from_iodata(data)
  end

  defp find_option(msg, type) do
    Enum.find(msg.options, fn %Option{type: t} -> t == type end)
  end

  defp build_reply(opts) do
    yiaddr = Keyword.get(opts, :yiaddr, {192, 168, 1, 100})
    siaddr = Keyword.get(opts, :siaddr, {192, 168, 1, 1})
    xid = Keyword.get(opts, :xid, @test_xid)
    options = Keyword.get(opts, :options, [])

    msg = %Message{
      op: 2,
      htype: 1,
      hlen: 6,
      hops: 0,
      xid: xid,
      secs: 0,
      flags: 0,
      ciaddr: {0, 0, 0, 0},
      yiaddr: yiaddr,
      siaddr: siaddr,
      giaddr: {0, 0, 0, 0},
      chaddr: @test_mac <> <<0::80>>,
      sname: <<0::512>>,
      file: <<0::1024>>,
      options: options
    }

    IO.iodata_to_binary(DHCP.Parameter.to_iodata(msg))
  end

  defp standard_offer_options do
    [
      %Option{type: 53, length: 1, value: <<2>>},
      %Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},
      %Option{type: 3, length: 4, value: <<192, 168, 1, 1>>},
      %Option{type: 6, length: 4, value: <<8, 8, 8, 8>>},
      %Option{type: 51, length: 4, value: <<0, 0, 14, 16>>},
      %Option{type: 54, length: 4, value: <<192, 168, 1, 1>>},
      %Option{type: 58, length: 4, value: <<0, 0, 7, 8>>},
      %Option{type: 59, length: 4, value: <<0, 0, 12, 84>>}
    ]
  end

  defp standard_ack_options do
    options = standard_offer_options()
    # Replace message type from OFFER (2) to ACK (5)
    Enum.map(options, fn
      %Option{type: 53} -> %Option{type: 53, length: 1, value: <<5>>}
      other -> other
    end)
  end

  # ── build_discover/3 ──

  describe "build_discover/3" do
    test "builds valid DHCPDISCOVER with correct header fields" do
      binary = Packet.build_discover(@test_mac, @test_xid)
      msg = parse_built_packet(binary)

      assert msg.op == 1
      assert msg.htype == 1
      assert msg.hlen == 6
      assert msg.hops == 0
      assert msg.xid == @test_xid
      assert msg.flags == 0x8000
      assert msg.ciaddr == {0, 0, 0, 0}
      assert msg.yiaddr == {0, 0, 0, 0}
    end

    test "includes DHCPDISCOVER message type (Option 53 = 1)" do
      binary = Packet.build_discover(@test_mac, @test_xid)
      msg = parse_built_packet(binary)
      opt = find_option(msg, 53)

      assert opt != nil
      assert opt.value == <<1>>
    end

    test "includes vendor class (Option 60) containing YellowDog" do
      binary = Packet.build_discover(@test_mac, @test_xid)
      msg = parse_built_packet(binary)
      opt = find_option(msg, 60)

      assert opt != nil
      assert String.starts_with?(opt.value, "YellowDog:")
    end

    test "includes vendor class ID (Option 124) with PEN bytes" do
      binary = Packet.build_discover(@test_mac, @test_xid)
      msg = parse_built_packet(binary)
      opt = find_option(msg, 124)

      assert opt != nil
      <<pen::32, _rest::binary>> = opt.value
      assert pen == VendorOptions.pen()
    end

    test "includes parameter request list (Option 55)" do
      binary = Packet.build_discover(@test_mac, @test_xid)
      msg = parse_built_packet(binary)
      opt = find_option(msg, 55)

      assert opt != nil
      # Should request at minimum: subnet mask (1), router (3), DNS (6),
      # lease time (51), T1 (58), T2 (59), vendor-specific (125)
      requested = :binary.bin_to_list(opt.value)
      assert 1 in requested
      assert 3 in requested
      assert 6 in requested
      assert 51 in requested
      assert 58 in requested
      assert 59 in requested
      assert 125 in requested
    end

    test "includes client ID (Option 61) with hardware type and MAC" do
      binary = Packet.build_discover(@test_mac, @test_xid)
      msg = parse_built_packet(binary)
      opt = find_option(msg, 61)

      assert opt != nil
      # Client ID: hardware type (1) + MAC address
      assert opt.value == <<1>> <> @test_mac
    end

    test "builds DHCPDISCOVER with hostname option when provided" do
      binary = Packet.build_discover(@test_mac, @test_xid, hostname: "yellow-node-1")
      msg = parse_built_packet(binary)
      opt = find_option(msg, 12)

      assert opt != nil
      assert opt.value == "yellow-node-1"
    end

    test "omits hostname option when not provided" do
      binary = Packet.build_discover(@test_mac, @test_xid)
      msg = parse_built_packet(binary)
      opt = find_option(msg, 12)

      assert opt == nil
    end

    test "includes custom version in vendor class string" do
      binary = Packet.build_discover(@test_mac, @test_xid, version: "2.5")
      msg = parse_built_packet(binary)
      opt = find_option(msg, 60)

      assert String.contains?(opt.value, "2.5")
    end

    test "includes capabilities in vendor class string" do
      binary = Packet.build_discover(@test_mac, @test_xid, capabilities: [:dns, :dhcp])
      msg = parse_built_packet(binary)
      opt = find_option(msg, 60)

      assert String.contains?(opt.value, "dns,dhcp")
    end

    test "chaddr is padded to 16 bytes" do
      binary = Packet.build_discover(@test_mac, @test_xid)
      msg = parse_built_packet(binary)

      assert byte_size(msg.chaddr) == 16
      assert :binary.part(msg.chaddr, 0, 6) == @test_mac
    end
  end

  # ── build_request/5 ──

  describe "build_request/5" do
    test "builds valid DHCPREQUEST with correct message type" do
      server_ip = {192, 168, 1, 1}
      offered_ip = {192, 168, 1, 100}

      binary = Packet.build_request(@test_mac, @test_xid, server_ip, offered_ip)
      msg = parse_built_packet(binary)
      opt = find_option(msg, 53)

      assert opt.value == <<3>>
    end

    test "includes requested IP address (Option 50)" do
      server_ip = {192, 168, 1, 1}
      offered_ip = {192, 168, 1, 100}

      binary = Packet.build_request(@test_mac, @test_xid, server_ip, offered_ip)
      msg = parse_built_packet(binary)
      opt = find_option(msg, 50)

      assert opt != nil
      assert opt.value == <<192, 168, 1, 100>>
    end

    test "includes server identifier (Option 54)" do
      server_ip = {10, 0, 0, 1}
      offered_ip = {10, 0, 0, 50}

      binary = Packet.build_request(@test_mac, @test_xid, server_ip, offered_ip)
      msg = parse_built_packet(binary)
      opt = find_option(msg, 54)

      assert opt != nil
      assert opt.value == <<10, 0, 0, 1>>
    end

    test "includes vendor class option" do
      binary =
        Packet.build_request(@test_mac, @test_xid, {192, 168, 1, 1}, {192, 168, 1, 100})

      msg = parse_built_packet(binary)
      opt = find_option(msg, 60)

      assert opt != nil
      assert String.starts_with?(opt.value, "YellowDog:")
    end

    test "includes vendor class ID (Option 124)" do
      binary =
        Packet.build_request(@test_mac, @test_xid, {192, 168, 1, 1}, {192, 168, 1, 100})

      msg = parse_built_packet(binary)
      opt = find_option(msg, 124)

      assert opt != nil
    end

    test "sets broadcast flag" do
      binary =
        Packet.build_request(@test_mac, @test_xid, {192, 168, 1, 1}, {192, 168, 1, 100})

      msg = parse_built_packet(binary)
      assert msg.flags == 0x8000
    end
  end

  # ── build_decline/4 ──

  describe "build_decline/4" do
    test "builds valid DHCPDECLINE with correct message type" do
      binary = Packet.build_decline(@test_mac, @test_xid, {192, 168, 1, 1}, {192, 168, 1, 100})
      msg = parse_built_packet(binary)
      opt = find_option(msg, 53)

      assert opt.value == <<4>>
    end

    test "includes requested IP and server ID" do
      binary = Packet.build_decline(@test_mac, @test_xid, {10, 0, 0, 1}, {10, 0, 0, 50})
      msg = parse_built_packet(binary)

      opt50 = find_option(msg, 50)
      opt54 = find_option(msg, 54)

      assert opt50.value == <<10, 0, 0, 50>>
      assert opt54.value == <<10, 0, 0, 1>>
    end
  end

  # ── build_release/4 ──

  describe "build_release/4" do
    test "builds valid DHCPRELEASE with correct message type" do
      binary = Packet.build_release(@test_mac, @test_xid, {192, 168, 1, 1}, {192, 168, 1, 100})
      msg = parse_built_packet(binary)
      opt = find_option(msg, 53)

      assert opt.value == <<7>>
    end

    test "sets ciaddr to client IP" do
      binary = Packet.build_release(@test_mac, @test_xid, {10, 0, 0, 1}, {10, 0, 0, 50})
      msg = parse_built_packet(binary)

      assert msg.ciaddr == {10, 0, 0, 50}
    end

    test "flags is 0 (not broadcast) for release" do
      binary = Packet.build_release(@test_mac, @test_xid, {192, 168, 1, 1}, {192, 168, 1, 100})
      msg = parse_built_packet(binary)

      assert msg.flags == 0
    end

    test "includes server identifier" do
      binary = Packet.build_release(@test_mac, @test_xid, {172, 16, 0, 1}, {172, 16, 0, 100})
      msg = parse_built_packet(binary)
      opt = find_option(msg, 54)

      assert opt.value == <<172, 16, 0, 1>>
    end
  end

  # ── parse_reply/1 ──

  describe "parse_reply/1" do
    test "parses DHCPOFFER reply" do
      data = build_reply(options: standard_offer_options())
      assert {:offer, %Lease{} = lease} = Packet.parse_reply(data)

      assert lease.ip == {192, 168, 1, 100}
      assert lease.subnet_mask == {255, 255, 255, 0}
      assert lease.router == {192, 168, 1, 1}
      assert lease.dns_servers == [{8, 8, 8, 8}]
      assert lease.server_ip == {192, 168, 1, 1}
      assert lease.lease_time == 3600
      assert lease.t1 == 1800
      assert lease.t2 == 3156
    end

    test "parses DHCPACK reply with lease fields" do
      data = build_reply(options: standard_ack_options())
      assert {:ack, %Lease{} = lease} = Packet.parse_reply(data)

      assert lease.ip == {192, 168, 1, 100}
      assert lease.lease_time == 3600
      assert lease.t1 == 1800
      assert lease.t2 == 3156
      assert %DateTime{} = lease.obtained_at
    end

    test "parses DHCPACK with Yellow Dog vendor options" do
      pen = VendorOptions.pen()

      sub_opts =
        <<1, 21, "http://localhost:4270">> <>
          <<2, 6, "srv-01">> <>
          <<4, 8, "mytoken!">>

      vendor_data = <<pen::32, byte_size(sub_opts)::8, sub_opts::binary>>

      options =
        standard_ack_options() ++
          [%Option{type: 125, length: byte_size(vendor_data), value: vendor_data}]

      data = build_reply(options: options)
      assert {:ack, %Lease{} = lease} = Packet.parse_reply(data)

      assert lease.yellowdog_server == true
      assert lease.control_url == "http://localhost:4270"
      assert lease.server_id == "srv-01"
      assert lease.auth_token == "mytoken!"
    end

    test "parses DHCPNAK reply" do
      reason_str = "address in use!"

      nak_options = [
        %Option{type: 53, length: 1, value: <<6>>},
        %Option{type: 56, length: byte_size(reason_str), value: reason_str}
      ]

      data = build_reply(options: nak_options)
      assert {:nak, reason} = Packet.parse_reply(data)
      assert reason == "address in use!"
    end

    test "parses DHCPNAK with default reason when Option 56 absent" do
      nak_options = [
        %Option{type: 53, length: 1, value: <<6>>}
      ]

      data = build_reply(options: nak_options)
      assert {:nak, "DHCPNAK received"} = Packet.parse_reply(data)
    end

    test "handles missing message type" do
      # Build a reply with no Option 53
      options = [
        %Option{type: 1, length: 4, value: <<255, 255, 255, 0>>}
      ]

      data = build_reply(options: options)
      assert {:error, :missing_message_type} = Packet.parse_reply(data)
    end

    test "handles malformed packets" do
      assert {:error, _reason} = Packet.parse_reply(<<1, 2, 3>>)
    end

    test "handles completely empty data" do
      assert {:error, _reason} = Packet.parse_reply(<<>>)
    end

    test "uses default lease time when Option 51 absent" do
      options = [
        %Option{type: 53, length: 1, value: <<5>>},
        %Option{type: 54, length: 4, value: <<192, 168, 1, 1>>}
      ]

      data = build_reply(options: options)
      assert {:ack, lease} = Packet.parse_reply(data)

      # Default lease_time = 3600
      assert lease.lease_time == 3600
    end

    test "uses default T1 and T2 when options absent" do
      options = [
        %Option{type: 53, length: 1, value: <<5>>},
        %Option{type: 51, length: 4, value: <<0, 0, 28, 32>>}
      ]

      data = build_reply(options: options)
      assert {:ack, lease} = Packet.parse_reply(data)

      lease_time = 7200
      assert lease.lease_time == lease_time
      # T1 default = lease_time / 2
      assert lease.t1 == div(lease_time, 2)
      # T2 default = lease_time * 7 / 8
      assert lease.t2 == div(lease_time * 7, 8)
    end

    test "parses multiple DNS servers" do
      options = [
        %Option{type: 53, length: 1, value: <<5>>},
        %Option{type: 6, length: 8, value: <<8, 8, 8, 8, 1, 1, 1, 1>>}
      ]

      data = build_reply(options: options)
      assert {:ack, lease} = Packet.parse_reply(data)

      assert lease.dns_servers == [{8, 8, 8, 8}, {1, 1, 1, 1}]
    end

    test "extracts domain name from Option 15" do
      options = [
        %Option{type: 53, length: 1, value: <<5>>},
        %Option{type: 15, length: 11, value: "example.com"}
      ]

      data = build_reply(options: options)
      assert {:ack, lease} = Packet.parse_reply(data)

      assert lease.domain_name == "example.com"
    end

    test "extracts MTU from Option 26" do
      options = [
        %Option{type: 53, length: 1, value: <<5>>},
        %Option{type: 26, length: 2, value: <<0x05, 0xDC>>}
      ]

      data = build_reply(options: options)
      assert {:ack, lease} = Packet.parse_reply(data)

      assert lease.mtu == 1500
    end

    test "sets yellowdog_server to false when no vendor options" do
      data = build_reply(options: standard_ack_options())
      assert {:ack, lease} = Packet.parse_reply(data)

      assert lease.yellowdog_server == false
    end

    test "sets yellowdog_server to false when vendor PEN mismatches" do
      wrong_pen = 11_111
      sub_opts = <<1, 3, "url">>
      vendor_data = <<wrong_pen::32, byte_size(sub_opts)::8, sub_opts::binary>>

      options =
        standard_ack_options() ++
          [%Option{type: 125, length: byte_size(vendor_data), value: vendor_data}]

      data = build_reply(options: options)
      assert {:ack, lease} = Packet.parse_reply(data)

      assert lease.yellowdog_server == false
    end

    test "preserves xid from reply" do
      custom_xid = 0xDEADBEEF
      data = build_reply(xid: custom_xid, options: standard_ack_options())
      assert {:ack, lease} = Packet.parse_reply(data)

      assert lease.xid == custom_xid
    end
  end
end
