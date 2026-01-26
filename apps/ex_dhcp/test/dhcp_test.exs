defmodule DHCPTest do
  use ExUnit.Case, async: true

  describe "module structure" do
    test "DHCP module is defined and loadable" do
      assert Code.ensure_loaded?(DHCP)
    end

    test "exports to_iodata/1" do
      assert function_exported?(DHCP, :to_iodata, 1)
    end
  end

  describe "to_iodata/1 with DHCPv4.Message" do
    test "serializes a new DHCPv4 message" do
      message = DHCPv4.Message.new()
      result = DHCP.to_iodata(message)
      assert is_binary(result)
    end

    test "serializes DHCPv4 message to valid wire format" do
      message = %DHCPv4.Message{
        op: 1,
        htype: 1,
        hlen: 6,
        hops: 0,
        xid: 0x12345678,
        secs: 0,
        flags: 0,
        ciaddr: {0, 0, 0, 0},
        yiaddr: {0, 0, 0, 0},
        siaddr: {0, 0, 0, 0},
        giaddr: {0, 0, 0, 0},
        chaddr: <<0::8*16>>,
        sname: <<0::8*64>>,
        file: <<0::8*128>>,
        options: []
      }

      binary = DHCP.to_iodata(message)

      # Verify header fields in wire format
      <<op, htype, hlen, hops, xid::32, _rest::binary>> = binary
      assert op == 1
      assert htype == 1
      assert hlen == 6
      assert hops == 0
      assert xid == 0x12345678
    end

    test "preserves all DHCPv4 message fields through serialization" do
      message = %DHCPv4.Message{
        op: 2,
        htype: 1,
        hlen: 6,
        hops: 3,
        xid: 0xABCDEF12,
        secs: 300,
        flags: 0x8000,
        ciaddr: {192, 168, 1, 100},
        yiaddr: {10, 0, 0, 50},
        siaddr: {172, 16, 0, 1},
        giaddr: {192, 168, 1, 1},
        chaddr: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>> <> <<0::10*8>>,
        sname: <<0::8*64>>,
        file: <<0::8*128>>,
        options: []
      }

      binary = DHCP.to_iodata(message)

      # Parse header fields
      <<
        op::8,
        htype::8,
        hlen::8,
        hops::8,
        xid::32,
        secs::16,
        flags::16,
        ciaddr::32,
        yiaddr::32,
        siaddr::32,
        giaddr::32,
        chaddr::binary-size(16),
        _sname::binary-size(64),
        _file::binary-size(128),
        _options::binary
      >> = binary

      assert op == 2
      assert htype == 1
      assert hlen == 6
      assert hops == 3
      assert xid == 0xABCDEF12
      assert secs == 300
      assert flags == 0x8000
      assert <<ciaddr::32>> == <<192, 168, 1, 100>>
      assert <<yiaddr::32>> == <<10, 0, 0, 50>>
      assert <<siaddr::32>> == <<172, 16, 0, 1>>
      assert <<giaddr::32>> == <<192, 168, 1, 1>>
      assert chaddr == <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>> <> <<0::10*8>>
    end
  end

  describe "to_iodata/1 with DHCPv4.Message.Option" do
    test "serializes a simple option" do
      option = DHCPv4.Message.Option.new(53, 1, <<1>>)
      result = DHCP.to_iodata(option)
      assert result == <<53, 1, 1>>
    end

    test "serializes option with message type DISCOVER" do
      option = DHCPv4.Message.Option.new(53, 1, <<1>>)
      result = DHCP.to_iodata(option)
      # Option 53 (DHCP Message Type), length 1, value 1 (DISCOVER)
      assert result == <<53, 1, 1>>
    end

    test "serializes option with subnet mask" do
      option = DHCPv4.Message.Option.new(1, 4, <<255, 255, 255, 0>>)
      result = DHCP.to_iodata(option)
      # Option 1 (Subnet Mask), length 4, value 255.255.255.0
      assert result == <<1, 4, 255, 255, 255, 0>>
    end

    test "serializes option with router address" do
      option = DHCPv4.Message.Option.new(3, 4, <<192, 168, 1, 1>>)
      result = DHCP.to_iodata(option)
      # Option 3 (Router), length 4, value 192.168.1.1
      assert result == <<3, 4, 192, 168, 1, 1>>
    end

    test "serializes option with DNS server addresses" do
      # Two DNS servers: 8.8.8.8 and 8.8.4.4
      option = DHCPv4.Message.Option.new(6, 8, <<8, 8, 8, 8, 8, 8, 4, 4>>)
      result = DHCP.to_iodata(option)
      # Option 6 (DNS), length 8, values
      assert result == <<6, 8, 8, 8, 8, 8, 8, 8, 4, 4>>
    end

    test "serializes option with lease time" do
      # 1 hour lease = 3600 seconds
      option = DHCPv4.Message.Option.new(51, 4, <<0, 0, 14, 16>>)
      result = DHCP.to_iodata(option)
      # Option 51 (Lease Time), length 4, value 3600
      assert result == <<51, 4, 0, 0, 14, 16>>
    end
  end

  describe "to_iodata/1 with DHCPv6.Message" do
    test "serializes a new DHCPv6 message" do
      message = DHCPv6.Message.new()
      result = DHCP.to_iodata(message)
      assert is_binary(result)
    end

    test "serializes DHCPv6 SOLICIT message" do
      message = %DHCPv6.Message{
        # SOLICIT
        msg_type: 1,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: []
      }

      binary = DHCP.to_iodata(message)

      <<msg_type, txn_id::binary-size(3), _rest::binary>> = binary
      assert msg_type == 1
      assert txn_id == <<0x12, 0x34, 0x56>>
    end

    test "serializes DHCPv6 ADVERTISE message" do
      message = %DHCPv6.Message{
        # ADVERTISE
        msg_type: 2,
        transaction_id: <<0xAB, 0xCD, 0xEF>>,
        options: []
      }

      binary = DHCP.to_iodata(message)

      <<msg_type, txn_id::binary-size(3), _rest::binary>> = binary
      assert msg_type == 2
      assert txn_id == <<0xAB, 0xCD, 0xEF>>
    end

    test "serializes all DHCPv6 message types" do
      # DHCPv6 message types from RFC 3315
      message_types = [
        {1, "SOLICIT"},
        {2, "ADVERTISE"},
        {3, "REQUEST"},
        {4, "CONFIRM"},
        {5, "RENEW"},
        {6, "REBIND"},
        {7, "REPLY"},
        {8, "RELEASE"},
        {9, "DECLINE"},
        {10, "RECONFIGURE"},
        {11, "INFORMATION-REQUEST"}
      ]

      for {type, _name} <- message_types do
        message = %DHCPv6.Message{
          msg_type: type,
          transaction_id: <<0, 0, 0>>,
          options: []
        }

        binary = DHCP.to_iodata(message)
        <<msg_type, _rest::binary>> = binary
        assert msg_type == type
      end
    end
  end

  describe "integration: round-trip serialization" do
    test "DHCPv4 message survives round-trip parse -> serialize -> parse" do
      original_binary =
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

      # Parse -> Serialize -> Parse
      msg1 = DHCPv4.Message.from_iodata(original_binary)
      serialized = DHCP.to_iodata(msg1)
      msg2 = DHCPv4.Message.from_iodata(serialized)

      # Verify key fields match
      assert msg1.op == msg2.op
      assert msg1.xid == msg2.xid
      assert msg1.ciaddr == msg2.ciaddr
      assert msg1.yiaddr == msg2.yiaddr
      assert msg1.chaddr == msg2.chaddr
    end
  end

  describe "DHCP.Parameter protocol" do
    test "protocol is defined" do
      assert Code.ensure_loaded?(DHCP.Parameter)
    end

    test "protocol requires to_iodata/1 callback" do
      callbacks = DHCP.Parameter.__protocol__(:functions)
      assert {:to_iodata, 1} in callbacks
    end

    test "DHCPv4.Message implements DHCP.Parameter" do
      message = DHCPv4.Message.new()
      assert DHCP.Parameter.impl_for(message) != nil
    end

    test "DHCPv4.Message.Option implements DHCP.Parameter" do
      option = DHCPv4.Message.Option.new(53, 1, <<1>>)
      assert DHCP.Parameter.impl_for(option) != nil
    end

    test "DHCPv6.Message implements DHCP.Parameter" do
      message = DHCPv6.Message.new()
      assert DHCP.Parameter.impl_for(message) != nil
    end
  end

  describe "DHCP.SecureRandom" do
    test "module is defined" do
      assert Code.ensure_loaded?(DHCP.SecureRandom)
    end

    test "generates random transaction IDs" do
      if function_exported?(DHCP.SecureRandom, :transaction_id, 0) do
        id1 = DHCP.SecureRandom.transaction_id()
        id2 = DHCP.SecureRandom.transaction_id()

        # Transaction IDs should be different
        assert id1 != id2
      end
    end

    test "generates random bytes" do
      if function_exported?(DHCP.SecureRandom, :bytes, 1) do
        bytes1 = DHCP.SecureRandom.bytes(16)
        bytes2 = DHCP.SecureRandom.bytes(16)

        # Random bytes should have correct length
        assert byte_size(bytes1) == 16
        assert byte_size(bytes2) == 16

        # Random bytes should be different (with very high probability)
        assert bytes1 != bytes2
      end
    end
  end

  describe "module documentation" do
    test "DHCP module has moduledoc" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(DHCP)
      assert is_binary(moduledoc)
      assert moduledoc =~ "Dynamic Host Configuration Protocol"
    end

    test "to_iodata/1 has documentation" do
      {:docs_v1, _, :elixir, _, _, _, function_docs} = Code.fetch_docs(DHCP)

      to_iodata_doc =
        Enum.find(function_docs, fn
          {{:function, :to_iodata, 1}, _, _, _, _} -> true
          _ -> false
        end)

      assert to_iodata_doc != nil
    end
  end
end
