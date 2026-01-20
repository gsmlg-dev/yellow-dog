defmodule DHCPv6.MessageTest do
  @moduledoc """
  Comprehensive unit tests for DHCPv6.Message.

  Tests cover:
  - Module structure and exports
  - Message creation and initialization
  - Binary parsing (from_iodata)
  - Binary serialization (to_iodata)
  - Round-trip encoding/decoding
  - DHCP.Parameter protocol implementation
  - All DHCPv6 message types
  """
  use ExUnit.Case, async: true

  alias DHCPv6.Message
  alias DHCPv6.Message.Option

  # DHCPv6 Message Types
  @solicit 1
  @advertise 2
  @request 3
  @confirm 4
  @renew 5
  @rebind 6
  @reply 7
  @release 8
  @decline 9
  @reconfigure 10
  @information_request 11
  @relay_forw 12
  @relay_repl 13

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Message)
    end

    test "exports new/0" do
      Code.ensure_loaded!(Message)
      assert Kernel.function_exported?(Message, :new, 0)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Message)
      assert Kernel.function_exported?(Message, :from_iodata, 1)
    end

    test "exports to_iodata/1" do
      Code.ensure_loaded!(Message)
      assert Kernel.function_exported?(Message, :to_iodata, 1)
    end

    test "defines struct with required fields" do
      message = %Message{}
      assert Map.has_key?(message, :msg_type)
      assert Map.has_key?(message, :transaction_id)
      assert Map.has_key?(message, :options)
    end
  end

  describe "new/0" do
    test "returns a Message struct" do
      message = Message.new()
      assert %Message{} = message
    end

    test "initializes msg_type to 0" do
      message = Message.new()
      assert message.msg_type == 0
    end

    test "initializes transaction_id to 3-byte zero binary" do
      message = Message.new()
      assert message.transaction_id == <<0, 0, 0>>
    end

    test "initializes options to empty list" do
      message = Message.new()
      assert message.options == []
    end
  end

  describe "from_iodata/1" do
    test "parses minimal DHCPv6 message (no options)" do
      # SOLICIT with transaction ID 0x123456
      data = <<@solicit, 0x12, 0x34, 0x56>>

      {:ok, message} = Message.from_iodata(data)

      assert message.msg_type == @solicit
      assert message.transaction_id == <<0x12, 0x34, 0x56>>
      assert message.options == []
    end

    test "parses message with single option" do
      # SOLICIT with Elapsed Time option (code 8, 2 bytes)
      option_data = <<0, 8, 0, 2, 0, 100>>
      data = <<@solicit, 0x12, 0x34, 0x56>> <> option_data

      {:ok, message} = Message.from_iodata(data)

      assert message.msg_type == @solicit
      assert length(message.options) == 1
      [option] = message.options
      assert option.option_code == 8
      assert option.option_data == <<0, 100>>
    end

    test "parses message with multiple options" do
      # SOLICIT with Elapsed Time and Option Request
      elapsed_time = <<0, 8, 0, 2, 0, 100>>
      option_request = <<0, 6, 0, 4, 0, 23, 0, 24>>
      data = <<@solicit, 0x12, 0x34, 0x56>> <> elapsed_time <> option_request

      {:ok, message} = Message.from_iodata(data)

      assert length(message.options) == 2
    end

    test "parses ADVERTISE message" do
      data = <<@advertise, 0xAB, 0xCD, 0xEF>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @advertise
    end

    test "parses REQUEST message" do
      data = <<@request, 0x11, 0x22, 0x33>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @request
    end

    test "parses CONFIRM message" do
      data = <<@confirm, 0x44, 0x55, 0x66>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @confirm
    end

    test "parses RENEW message" do
      data = <<@renew, 0x77, 0x88, 0x99>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @renew
    end

    test "parses REBIND message" do
      data = <<@rebind, 0xAA, 0xBB, 0xCC>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @rebind
    end

    test "parses REPLY message" do
      data = <<@reply, 0xDD, 0xEE, 0xFF>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @reply
    end

    test "parses RELEASE message" do
      data = <<@release, 0x00, 0x11, 0x22>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @release
    end

    test "parses DECLINE message" do
      data = <<@decline, 0x33, 0x44, 0x55>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @decline
    end

    test "parses RECONFIGURE message" do
      data = <<@reconfigure, 0x66, 0x77, 0x88>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @reconfigure
    end

    test "parses INFORMATION-REQUEST message" do
      data = <<@information_request, 0x99, 0xAA, 0xBB>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @information_request
    end

    test "parses RELAY-FORW message" do
      data = <<@relay_forw, 0xCC, 0xDD, 0xEE>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @relay_forw
    end

    test "parses RELAY-REPL message" do
      data = <<@relay_repl, 0xFF, 0x00, 0x11>>
      {:ok, message} = Message.from_iodata(data)
      assert message.msg_type == @relay_repl
    end

    test "returns error for empty data" do
      {:error, reason} = Message.from_iodata(<<>>)
      assert is_binary(reason)
    end

    test "returns error for data too short" do
      {:error, _} = Message.from_iodata(<<1, 2>>)
    end

    test "returns error for truncated option" do
      # Option header but missing data
      data = <<@solicit, 0x12, 0x34, 0x56, 0, 8, 0, 10, 0>>
      {:error, _} = Message.from_iodata(data)
    end

    test "preserves transaction ID bytes exactly" do
      data = <<@solicit, 0xFF, 0x00, 0xFF>>
      {:ok, message} = Message.from_iodata(data)
      assert message.transaction_id == <<0xFF, 0x00, 0xFF>>
    end
  end

  describe "to_iodata/1" do
    test "serializes minimal message" do
      message = %Message{
        msg_type: @solicit,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: []
      }

      binary = Message.to_iodata(message)

      assert binary == <<@solicit, 0x12, 0x34, 0x56>>
    end

    test "serializes message with option" do
      option = Option.new(8, <<0, 100>>)

      message = %Message{
        msg_type: @advertise,
        transaction_id: <<0xAB, 0xCD, 0xEF>>,
        options: [option]
      }

      binary = Message.to_iodata(message)

      assert binary == <<@advertise, 0xAB, 0xCD, 0xEF, 0, 8, 0, 2, 0, 100>>
    end

    test "serializes message with multiple options" do
      opt1 = Option.new(8, <<0, 100>>)
      opt2 = Option.new(7, <<255>>)

      message = %Message{
        msg_type: @reply,
        transaction_id: <<0x11, 0x22, 0x33>>,
        options: [opt1, opt2]
      }

      binary = Message.to_iodata(message)

      assert binary ==
               <<@reply, 0x11, 0x22, 0x33, 0, 8, 0, 2, 0, 100, 0, 7, 0, 1, 255>>
    end

    test "handles short transaction_id by using zeros" do
      message = %Message{
        msg_type: @solicit,
        transaction_id: <<0x12>>,
        options: []
      }

      binary = Message.to_iodata(message)

      # Falls back to <<0, 0, 0>>
      assert binary == <<@solicit, 0, 0, 0>>
    end

    test "handles long transaction_id by using zeros" do
      message = %Message{
        msg_type: @solicit,
        transaction_id: <<0x12, 0x34, 0x56, 0x78>>,
        options: []
      }

      binary = Message.to_iodata(message)

      # Falls back to <<0, 0, 0>>
      assert binary == <<@solicit, 0, 0, 0>>
    end

    test "handles nil transaction_id" do
      message = %Message{
        msg_type: @solicit,
        transaction_id: nil,
        options: []
      }

      # Implementation crashes on nil - this is expected behavior
      # as the API requires a valid binary transaction_id
      assert_raise ArgumentError, fn ->
        Message.to_iodata(message)
      end
    end

    test "serializes all message types" do
      for msg_type <- 1..13 do
        message = %Message{
          msg_type: msg_type,
          transaction_id: <<0x12, 0x34, 0x56>>,
          options: []
        }

        binary = Message.to_iodata(message)
        <<first_byte, _::binary>> = binary
        assert first_byte == msg_type
      end
    end
  end

  describe "round-trip encoding/decoding" do
    test "round-trip for minimal message" do
      original = %Message{
        msg_type: @solicit,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: []
      }

      binary = Message.to_iodata(original)
      {:ok, decoded} = Message.from_iodata(binary)

      assert decoded.msg_type == original.msg_type
      assert decoded.transaction_id == original.transaction_id
      assert decoded.options == original.options
    end

    test "round-trip for message with options" do
      option = Option.new(8, <<0, 200>>)

      original = %Message{
        msg_type: @reply,
        transaction_id: <<0xAB, 0xCD, 0xEF>>,
        options: [option]
      }

      binary = Message.to_iodata(original)
      {:ok, decoded} = Message.from_iodata(binary)

      assert decoded.msg_type == original.msg_type
      assert decoded.transaction_id == original.transaction_id
      assert length(decoded.options) == 1
      [decoded_option] = decoded.options
      assert decoded_option.option_code == option.option_code
      assert decoded_option.option_data == option.option_data
    end

    test "round-trip for all message types" do
      for msg_type <- 1..13 do
        original = %Message{
          msg_type: msg_type,
          transaction_id: <<0xFF, 0x00, 0xFF>>,
          options: [Option.new(7, <<128>>)]
        }

        binary = Message.to_iodata(original)
        {:ok, decoded} = Message.from_iodata(binary)

        assert decoded.msg_type == msg_type
      end
    end

    test "round-trip preserves option order" do
      options = [
        Option.new(8, <<0, 100>>),
        Option.new(7, <<128>>),
        Option.new(6, <<0, 23, 0, 24>>)
      ]

      original = %Message{
        msg_type: @solicit,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: options
      }

      binary = Message.to_iodata(original)
      {:ok, decoded} = Message.from_iodata(binary)

      assert length(decoded.options) == 3

      Enum.zip(options, decoded.options)
      |> Enum.each(fn {orig, dec} ->
        assert orig.option_code == dec.option_code
        assert orig.option_data == dec.option_data
      end)
    end
  end

  describe "DHCP.Parameter protocol" do
    test "implements DHCP.Parameter protocol" do
      message = Message.new()

      # Should not raise - protocol is implemented
      binary = DHCP.Parameter.to_iodata(message)
      assert is_binary(binary)
    end

    test "protocol to_iodata matches Message.to_iodata" do
      message = %Message{
        msg_type: @solicit,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: [Option.new(8, <<0, 100>>)]
      }

      assert DHCP.Parameter.to_iodata(message) == Message.to_iodata(message)
    end
  end

  describe "edge cases" do
    test "handles maximum transaction ID values" do
      data = <<@solicit, 0xFF, 0xFF, 0xFF>>
      {:ok, message} = Message.from_iodata(data)
      assert message.transaction_id == <<0xFF, 0xFF, 0xFF>>
    end

    test "handles minimum transaction ID values" do
      data = <<@solicit, 0x00, 0x00, 0x00>>
      {:ok, message} = Message.from_iodata(data)
      assert message.transaction_id == <<0x00, 0x00, 0x00>>
    end

    test "handles large option data" do
      # Option with 256 bytes of data
      large_data = :crypto.strong_rand_bytes(256)
      option = Option.new(100, large_data)

      message = %Message{
        msg_type: @reply,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: [option]
      }

      binary = Message.to_iodata(message)
      {:ok, decoded} = Message.from_iodata(binary)

      [decoded_option] = decoded.options
      assert decoded_option.option_data == large_data
    end

    test "handles empty option data" do
      option = Option.new(6, <<>>)

      message = %Message{
        msg_type: @solicit,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: [option]
      }

      binary = Message.to_iodata(message)
      {:ok, decoded} = Message.from_iodata(binary)

      [decoded_option] = decoded.options
      assert decoded_option.option_data == <<>>
    end

    test "handles many options" do
      options = for i <- 1..20, do: Option.new(rem(i, 255) + 1, <<i>>)

      message = %Message{
        msg_type: @reply,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: options
      }

      binary = Message.to_iodata(message)
      {:ok, decoded} = Message.from_iodata(binary)

      assert length(decoded.options) == 20
    end
  end

  describe "realistic DHCPv6 scenarios" do
    test "SOLICIT message with Client ID and Elapsed Time" do
      # Client DUID (Link-layer address plus time)
      client_duid = <<0, 1, 0, 1, 0x5A, 0xB8, 0x45, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>
      client_id = Option.new(1, client_duid)

      # Elapsed Time = 0
      elapsed_time = Option.new(8, <<0, 0>>)

      # Option Request (DNS servers + Domain List)
      option_request = Option.new(6, <<0, 23, 0, 24>>)

      message = %Message{
        msg_type: @solicit,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: [client_id, elapsed_time, option_request]
      }

      binary = Message.to_iodata(message)
      {:ok, decoded} = Message.from_iodata(binary)

      assert decoded.msg_type == @solicit
      assert length(decoded.options) == 3
    end

    test "ADVERTISE message with Server ID and IA_NA" do
      # Server DUID
      server_duid = <<0, 1, 0, 1, 0x5A, 0xB8, 0x46, 0x00, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      server_id = Option.new(2, server_duid)

      # Preference
      preference = Option.new(7, <<255>>)

      message = %Message{
        msg_type: @advertise,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: [server_id, preference]
      }

      binary = Message.to_iodata(message)
      {:ok, decoded} = Message.from_iodata(binary)

      assert decoded.msg_type == @advertise
    end

    test "REPLY message with DNS servers" do
      # DNS Recursive Name Server (Google IPv6 DNS)
      dns_server_ipv6 = <<0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0x00, 0x00,
                          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x88, 0x88>>
      dns_servers = Option.new(23, dns_server_ipv6)

      message = %Message{
        msg_type: @reply,
        transaction_id: <<0xAB, 0xCD, 0xEF>>,
        options: [dns_servers]
      }

      binary = Message.to_iodata(message)
      {:ok, decoded} = Message.from_iodata(binary)

      [dns_option] = decoded.options
      assert dns_option.option_code == 23
      assert byte_size(dns_option.option_data) == 16
    end
  end
end
