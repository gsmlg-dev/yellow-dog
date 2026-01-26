defmodule DHCPv4.MessageTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias DHCPv4.Message

  # RFC 2131 magic cookie
  @magic_cookie <<99, 130, 83, 99>>

  describe "module structure" do
    test "Message module is defined and loadable" do
      assert Code.ensure_loaded?(Message)
    end

    test "Message struct has all expected fields" do
      fields = Map.keys(%Message{}) -- [:__struct__]

      assert :op in fields
      assert :htype in fields
      assert :hlen in fields
      assert :hops in fields
      assert :xid in fields
      assert :secs in fields
      assert :flags in fields
      assert :ciaddr in fields
      assert :yiaddr in fields
      assert :siaddr in fields
      assert :giaddr in fields
      assert :chaddr in fields
      assert :sname in fields
      assert :file in fields
      assert :options in fields
    end

    test "exports new/0" do
      assert function_exported?(Message, :new, 0)
    end

    test "exports from_iodata/1" do
      assert function_exported?(Message, :from_iodata, 1)
    end
  end

  describe "new/0" do
    test "creates a new message with default values" do
      msg = Message.new()
      assert %Message{} = msg
    end

    test "sets op to 0" do
      assert Message.new().op == 0
    end

    test "sets htype to 0" do
      assert Message.new().htype == 0
    end

    test "sets hlen to 0" do
      assert Message.new().hlen == 0
    end

    test "sets hops to 0" do
      assert Message.new().hops == 0
    end

    test "sets xid to 0" do
      assert Message.new().xid == 0
    end

    test "sets secs to 0" do
      assert Message.new().secs == 0
    end

    test "sets flags to 0" do
      assert Message.new().flags == 0
    end

    test "sets ciaddr to {0, 0, 0, 0}" do
      assert Message.new().ciaddr == {0, 0, 0, 0}
    end

    test "sets yiaddr to {0, 0, 0, 0}" do
      assert Message.new().yiaddr == {0, 0, 0, 0}
    end

    test "sets siaddr to {0, 0, 0, 0}" do
      assert Message.new().siaddr == {0, 0, 0, 0}
    end

    test "sets giaddr to {0, 0, 0, 0}" do
      assert Message.new().giaddr == {0, 0, 0, 0}
    end

    test "sets chaddr to 16 zero bytes" do
      msg = Message.new()
      assert byte_size(msg.chaddr) == 16
      assert msg.chaddr == <<0::8*16>>
    end

    test "sets sname to 64 zero bytes" do
      msg = Message.new()
      assert byte_size(msg.sname) == 64
      assert msg.sname == <<0::8*64>>
    end

    test "sets file to 128 zero bytes" do
      msg = Message.new()
      assert byte_size(msg.file) == 128
      assert msg.file == <<0::8*128>>
    end

    test "sets options to empty list" do
      assert Message.new().options == []
    end
  end

  describe "from_iodata/1 - basic parsing" do
    test "parses minimal valid DHCP message" do
      # Build minimal message: header + magic cookie + end option
      raw = build_minimal_message()
      msg = Message.from_iodata(raw)
      assert %Message{} = msg
    end

    test "parses BOOTREQUEST message (op=1)" do
      raw = build_message(op: 1)
      msg = Message.from_iodata(raw)
      assert msg.op == 1
    end

    test "parses BOOTREPLY message (op=2)" do
      raw = build_message(op: 2)
      msg = Message.from_iodata(raw)
      assert msg.op == 2
    end

    test "parses Ethernet hardware type (htype=1)" do
      raw = build_message(htype: 1)
      msg = Message.from_iodata(raw)
      assert msg.htype == 1
    end

    test "parses Token Ring hardware type (htype=6)" do
      raw = build_message(htype: 6)
      msg = Message.from_iodata(raw)
      assert msg.htype == 6
    end

    test "parses Ethernet hardware length (hlen=6)" do
      raw = build_message(hlen: 6)
      msg = Message.from_iodata(raw)
      assert msg.hlen == 6
    end

    test "parses hops value" do
      raw = build_message(hops: 3)
      msg = Message.from_iodata(raw)
      assert msg.hops == 3
    end

    test "parses transaction ID (xid)" do
      raw = build_message(xid: 0xABCDEF12)
      msg = Message.from_iodata(raw)
      assert msg.xid == 0xABCDEF12
    end

    test "parses maximum transaction ID" do
      raw = build_message(xid: 0xFFFFFFFF)
      msg = Message.from_iodata(raw)
      assert msg.xid == 0xFFFFFFFF
    end

    test "parses secs value" do
      raw = build_message(secs: 300)
      msg = Message.from_iodata(raw)
      assert msg.secs == 300
    end

    test "parses flags value" do
      # Broadcast flag
      raw = build_message(flags: 0x8000)
      msg = Message.from_iodata(raw)
      assert msg.flags == 0x8000
    end
  end

  describe "from_iodata/1 - IP address parsing" do
    test "parses ciaddr" do
      raw = build_message(ciaddr: {192, 168, 1, 100})
      msg = Message.from_iodata(raw)
      assert msg.ciaddr == {192, 168, 1, 100}
    end

    test "parses yiaddr" do
      raw = build_message(yiaddr: {10, 0, 0, 50})
      msg = Message.from_iodata(raw)
      assert msg.yiaddr == {10, 0, 0, 50}
    end

    test "parses siaddr" do
      raw = build_message(siaddr: {172, 16, 0, 1})
      msg = Message.from_iodata(raw)
      assert msg.siaddr == {172, 16, 0, 1}
    end

    test "parses giaddr" do
      raw = build_message(giaddr: {192, 168, 1, 1})
      msg = Message.from_iodata(raw)
      assert msg.giaddr == {192, 168, 1, 1}
    end

    test "parses zero IP addresses" do
      raw = build_message(ciaddr: {0, 0, 0, 0})
      msg = Message.from_iodata(raw)
      assert msg.ciaddr == {0, 0, 0, 0}
    end

    test "parses broadcast IP address" do
      raw = build_message(yiaddr: {255, 255, 255, 255})
      msg = Message.from_iodata(raw)
      assert msg.yiaddr == {255, 255, 255, 255}
    end
  end

  describe "from_iodata/1 - hardware address parsing" do
    test "parses Ethernet MAC address in chaddr" do
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>> <> <<0::10*8>>
      raw = build_message(chaddr: mac)
      msg = Message.from_iodata(raw)

      assert byte_size(msg.chaddr) == 16
      <<actual_mac::binary-size(6), _rest::binary>> = msg.chaddr
      assert actual_mac == <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
    end

    test "parses full 16-byte chaddr field" do
      chaddr = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
      raw = build_message(chaddr: chaddr)
      msg = Message.from_iodata(raw)
      assert msg.chaddr == chaddr
    end
  end

  describe "from_iodata/1 - server name and file parsing" do
    test "parses empty sname (64 zero bytes)" do
      raw = build_message(sname: <<0::8*64>>)
      msg = Message.from_iodata(raw)
      assert byte_size(msg.sname) == 64
    end

    test "parses sname with server hostname" do
      hostname_str = "dhcp-server.local"
      pad_size = 64 - byte_size(hostname_str)
      hostname = hostname_str <> String.duplicate(<<0>>, pad_size)
      raw = build_message(sname: hostname)
      msg = Message.from_iodata(raw)

      assert String.trim_trailing(msg.sname, <<0>>) == "dhcp-server.local"
    end

    test "parses empty file (128 zero bytes)" do
      raw = build_message(file: <<0::8*128>>)
      msg = Message.from_iodata(raw)
      assert byte_size(msg.file) == 128
    end

    test "parses file with boot filename" do
      bootfile_str = "/pxelinux.0"
      pad_size = 128 - byte_size(bootfile_str)
      bootfile = bootfile_str <> String.duplicate(<<0>>, pad_size)
      raw = build_message(file: bootfile)
      msg = Message.from_iodata(raw)

      assert String.trim_trailing(msg.file, <<0>>) == "/pxelinux.0"
    end
  end

  describe "from_iodata/1 - real-world message parsing" do
    test "parses DHCPDISCOVER message" do
      raw =
        <<1, 1, 6, 0, 171, 205, 0, 217, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 44, 244, 50, 167, 213, 99, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 99, 130, 83, 99, 53, 1, 3, 57, 2, 5, 220, 50, 4, 10, 100, 10,
          85, 54, 4, 10, 100, 0, 1, 55, 12, 1, 3, 28, 6, 15, 44, 46, 47, 31, 33, 121, 43, 12, 10,
          69, 83, 80, 95, 65, 55, 68, 53, 54, 51, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0>>

      msg = Message.from_iodata(raw)

      assert %Message{} = msg
      assert msg.op == 1
      assert msg.htype == 1
      assert msg.hlen == 6
      assert msg.hops == 0
      assert msg.xid == 2_882_339_033
      assert msg.secs == 0
      assert msg.flags == 0
      assert msg.ciaddr == {0, 0, 0, 0}
      assert msg.yiaddr == {0, 0, 0, 0}
      assert msg.siaddr == {0, 0, 0, 0}
      assert msg.giaddr == {0, 0, 0, 0}

      chaddr = msg.chaddr |> String.trim(<<0>>) |> Base.encode16()
      assert chaddr == "2CF432A7D563"

      assert byte_size(msg.sname) == 64
      assert byte_size(msg.file) == 128
      assert length(msg.options) == 6
    end

    test "parses DHCPREQUEST message from surface-pro-7" do
      raw =
        <<1, 1, 6, 0, 9, 171, 153, 200, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 204, 249, 228, 97, 119, 104, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 99, 130, 83, 99, 53, 1, 3, 61, 7, 1, 204, 249, 228, 97, 119,
          104, 55, 17, 1, 2, 6, 12, 15, 26, 28, 121, 3, 33, 40, 41, 42, 119, 249, 252, 17, 57, 2,
          2, 64, 50, 4, 10, 100, 16, 177, 12, 13, 115, 117, 114, 102, 97, 99, 101, 45, 112, 114,
          111, 45, 55, 255>>

      msg = Message.from_iodata(raw)

      assert msg.op == 1
      assert msg.htype == 1
      assert msg.hlen == 6
      assert msg.hops == 0
      assert msg.xid == 162_240_968
      assert msg.secs == 1
      assert msg.flags == 0
      assert msg.ciaddr == {0, 0, 0, 0}

      chaddr = msg.chaddr |> String.trim(<<0>>) |> Base.encode16()
      assert chaddr == "CCF9E4617768"

      assert length(msg.options) == 6
    end
  end

  describe "DHCP.Parameter protocol implementation" do
    test "implements DHCP.Parameter protocol" do
      msg = Message.new()
      assert DHCP.Parameter.impl_for(msg) != nil
    end

    test "to_iodata returns binary" do
      msg = Message.new()
      binary = DHCP.Parameter.to_iodata(msg)
      assert is_binary(binary)
    end

    test "serializes message header correctly" do
      msg = %Message{
        op: 2,
        htype: 1,
        hlen: 6,
        hops: 0,
        xid: 0x12345678,
        secs: 100,
        flags: 0x8000,
        ciaddr: {192, 168, 1, 100},
        yiaddr: {192, 168, 1, 200},
        siaddr: {192, 168, 1, 1},
        giaddr: {0, 0, 0, 0},
        chaddr: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>> <> <<0::10*8>>,
        sname: <<0::8*64>>,
        file: <<0::8*128>>,
        options: []
      }

      binary = DHCP.Parameter.to_iodata(msg)

      <<op, htype, hlen, hops, xid::32, secs::16, flags::16, _rest::binary>> = binary

      assert op == 2
      assert htype == 1
      assert hlen == 6
      assert hops == 0
      assert xid == 0x12345678
      assert secs == 100
      assert flags == 0x8000
    end

    test "serializes IP addresses correctly" do
      msg = %Message{
        op: 1,
        htype: 1,
        hlen: 6,
        hops: 0,
        xid: 0,
        secs: 0,
        flags: 0,
        ciaddr: {10, 20, 30, 40},
        yiaddr: {50, 60, 70, 80},
        siaddr: {90, 100, 110, 120},
        giaddr: {130, 140, 150, 160},
        chaddr: <<0::8*16>>,
        sname: <<0::8*64>>,
        file: <<0::8*128>>,
        options: []
      }

      binary = DHCP.Parameter.to_iodata(msg)

      <<_header::binary-size(12), ciaddr::32, yiaddr::32, siaddr::32, giaddr::32, _rest::binary>> =
        binary

      assert ciaddr == 10 * 256 * 256 * 256 + 20 * 256 * 256 + 30 * 256 + 40
      assert yiaddr == 50 * 256 * 256 * 256 + 60 * 256 * 256 + 70 * 256 + 80
      assert siaddr == 90 * 256 * 256 * 256 + 100 * 256 * 256 + 110 * 256 + 120
      assert giaddr == 130 * 256 * 256 * 256 + 140 * 256 * 256 + 150 * 256 + 160
    end

    test "round-trip: parse -> serialize -> parse produces same message" do
      raw =
        <<1, 1, 6, 0, 171, 205, 0, 217, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 44, 244, 50, 167, 213, 99, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 99, 130, 83, 99, 53, 1, 3, 57, 2, 5, 220, 50, 4, 10, 100, 10,
          85, 54, 4, 10, 100, 0, 1, 55, 12, 1, 3, 28, 6, 15, 44, 46, 47, 31, 33, 121, 43, 12, 10,
          69, 83, 80, 95, 65, 55, 68, 53, 54, 51, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0>>

      msg1 = Message.from_iodata(raw)
      serialized = DHCP.Parameter.to_iodata(msg1)
      msg2 = Message.from_iodata(serialized)

      assert msg1.op == msg2.op
      assert msg1.htype == msg2.htype
      assert msg1.hlen == msg2.hlen
      assert msg1.hops == msg2.hops
      assert msg1.xid == msg2.xid
      assert msg1.secs == msg2.secs
      assert msg1.flags == msg2.flags
      assert msg1.ciaddr == msg2.ciaddr
      assert msg1.yiaddr == msg2.yiaddr
      assert msg1.siaddr == msg2.siaddr
      assert msg1.giaddr == msg2.giaddr
      assert msg1.chaddr == msg2.chaddr
      assert length(msg1.options) == length(msg2.options)
    end
  end

  describe "String.Chars protocol implementation" do
    test "implements String.Chars protocol" do
      msg = Message.new()
      assert String.Chars.impl_for(msg) != nil
    end

    test "to_string returns a string" do
      msg = %Message{
        op: 1,
        htype: 1,
        hlen: 6,
        hops: 0,
        xid: 12345,
        secs: 0,
        flags: 0,
        ciaddr: {0, 0, 0, 0},
        yiaddr: {192, 168, 1, 100},
        siaddr: {192, 168, 1, 1},
        giaddr: {0, 0, 0, 0},
        chaddr: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>> <> <<0::10*8>>,
        sname: <<0::8*64>>,
        file: <<0::8*128>>,
        options: []
      }

      str = to_string(msg)
      assert is_binary(str)
      assert str =~ "DHCP Message"
      assert str =~ "Operation: 1"
      assert str =~ "Transaction ID: 12345"
    end

    test "displays MAC address correctly" do
      msg = %Message{
        op: 1,
        htype: 1,
        hlen: 6,
        hops: 0,
        xid: 0,
        secs: 0,
        flags: 0,
        ciaddr: {0, 0, 0, 0},
        yiaddr: {0, 0, 0, 0},
        siaddr: {0, 0, 0, 0},
        giaddr: {0, 0, 0, 0},
        chaddr: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>> <> <<0::10*8>>,
        sname: <<0::8*64>>,
        file: <<0::8*128>>,
        options: []
      }

      str = to_string(msg)
      assert str =~ "aa:bb:cc:dd:ee:ff"
    end

    test "displays IP addresses correctly" do
      msg = %Message{
        op: 2,
        htype: 1,
        hlen: 6,
        hops: 0,
        xid: 0,
        secs: 0,
        flags: 0,
        ciaddr: {10, 0, 0, 100},
        yiaddr: {192, 168, 1, 50},
        siaddr: {172, 16, 0, 1},
        giaddr: {192, 168, 1, 1},
        chaddr: <<0::8*16>>,
        sname: <<0::8*64>>,
        file: <<0::8*128>>,
        options: []
      }

      str = to_string(msg)
      assert str =~ "10.0.0.100"
      assert str =~ "192.168.1.50"
      assert str =~ "172.16.0.1"
      assert str =~ "192.168.1.1"
    end
  end

  describe "RFC 2131 compliance" do
    test "minimum DHCP message size is 236 bytes (without options)" do
      # op(1) + htype(1) + hlen(1) + hops(1) + xid(4) + secs(2) + flags(2) +
      # ciaddr(4) + yiaddr(4) + siaddr(4) + giaddr(4) + chaddr(16) + sname(64) + file(128)
      # = 236 bytes
      raw = build_minimal_message()

      # Header is 236 bytes, plus magic cookie (4) and end option (1)
      assert byte_size(raw) >= 236 + 4 + 1
    end

    test "magic cookie must be 0x63825363" do
      raw = build_minimal_message()
      <<_header::binary-size(236), magic::binary-size(4), _rest::binary>> = raw
      assert magic == @magic_cookie
    end

    test "broadcast flag is bit 15 (0x8000)" do
      raw = build_message(flags: 0x8000)
      msg = Message.from_iodata(raw)

      # Bit 15 (MSB) is the broadcast flag
      assert (msg.flags &&& 0x8000) == 0x8000
    end

    test "chaddr field is always 16 bytes" do
      raw = build_message(chaddr: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>> <> <<0::10*8>>)
      msg = Message.from_iodata(raw)
      assert byte_size(msg.chaddr) == 16
    end

    test "sname field is always 64 bytes" do
      sname_str = "test.server.com"
      pad_size = 64 - byte_size(sname_str)
      raw = build_message(sname: sname_str <> String.duplicate(<<0>>, pad_size))
      msg = Message.from_iodata(raw)
      assert byte_size(msg.sname) == 64
    end

    test "file field is always 128 bytes" do
      file_str = "/boot/pxelinux.0"
      pad_size = 128 - byte_size(file_str)
      raw = build_message(file: file_str <> String.duplicate(<<0>>, pad_size))
      msg = Message.from_iodata(raw)
      assert byte_size(msg.file) == 128
    end
  end

  describe "edge cases" do
    test "parses message with all zero values" do
      raw =
        build_message(
          op: 0,
          htype: 0,
          hlen: 0,
          hops: 0,
          xid: 0,
          secs: 0,
          flags: 0,
          ciaddr: {0, 0, 0, 0},
          yiaddr: {0, 0, 0, 0},
          siaddr: {0, 0, 0, 0},
          giaddr: {0, 0, 0, 0}
        )

      msg = Message.from_iodata(raw)
      assert msg.op == 0
      assert msg.xid == 0
    end

    test "parses message with maximum byte values" do
      raw =
        build_message(
          op: 255,
          htype: 255,
          hlen: 255,
          hops: 255
        )

      msg = Message.from_iodata(raw)
      assert msg.op == 255
      assert msg.htype == 255
      assert msg.hlen == 255
      assert msg.hops == 255
    end

    test "parses message with maximum 16-bit values" do
      raw =
        build_message(
          secs: 65535,
          flags: 65535
        )

      msg = Message.from_iodata(raw)
      assert msg.secs == 65535
      assert msg.flags == 65535
    end

    test "parses message with maximum 32-bit xid" do
      raw = build_message(xid: 0xFFFFFFFF)
      msg = Message.from_iodata(raw)
      assert msg.xid == 0xFFFFFFFF
    end
  end

  # Helper functions to build test messages

  defp build_minimal_message do
    build_message([])
  end

  defp build_message(opts \\ []) do
    op = Keyword.get(opts, :op, 1)
    htype = Keyword.get(opts, :htype, 1)
    hlen = Keyword.get(opts, :hlen, 6)
    hops = Keyword.get(opts, :hops, 0)
    xid = Keyword.get(opts, :xid, 0)
    secs = Keyword.get(opts, :secs, 0)
    flags = Keyword.get(opts, :flags, 0)
    ciaddr = Keyword.get(opts, :ciaddr, {0, 0, 0, 0})
    yiaddr = Keyword.get(opts, :yiaddr, {0, 0, 0, 0})
    siaddr = Keyword.get(opts, :siaddr, {0, 0, 0, 0})
    giaddr = Keyword.get(opts, :giaddr, {0, 0, 0, 0})
    chaddr = Keyword.get(opts, :chaddr, <<0::8*16>>)
    sname = Keyword.get(opts, :sname, <<0::8*64>>)
    file = Keyword.get(opts, :file, <<0::8*128>>)

    <<
      op::8,
      htype::8,
      hlen::8,
      hops::8,
      xid::32,
      secs::16,
      flags::16,
      ip_to_binary(ciaddr)::binary,
      ip_to_binary(yiaddr)::binary,
      ip_to_binary(siaddr)::binary,
      ip_to_binary(giaddr)::binary,
      chaddr::binary,
      sname::binary,
      file::binary,
      # Magic cookie
      @magic_cookie::binary,
      # End option
      255
    >>
  end

  defp ip_to_binary({a, b, c, d}), do: <<a, b, c, d>>
end
