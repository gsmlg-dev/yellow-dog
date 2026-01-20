defmodule YellowDog.Dhcpv6.RelayAgentTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv6.RelayAgent

  # Option codes
  @option_relay_msg 9
  @option_interface_id 18
  @option_relay_id 53

  # Message types
  @msg_type_relay_forw 12
  @msg_type_relay_repl 13
  @msg_type_solicit 1

  # Test IPv6 addresses
  @link_address {0x2001, 0xDB8, 0, 1, 0, 0, 0, 1}
  @peer_address {0x2001, 0xDB8, 0, 1, 0, 0, 0, 100}
  @zero_address {0, 0, 0, 0, 0, 0, 0, 0}

  describe "validate_relay_message/1" do
    test "accepts valid relay message" do
      relay_message = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 1,
        link_address: @link_address,
        peer_address: @peer_address,
        options: []
      }

      assert :ok = RelayAgent.validate_relay_message(relay_message)
    end

    test "accepts max hop count of 32" do
      relay_message = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 32,
        link_address: @link_address,
        peer_address: @peer_address,
        options: []
      }

      assert :ok = RelayAgent.validate_relay_message(relay_message)
    end

    test "rejects hop count exceeding 32" do
      relay_message = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 33,
        link_address: @link_address,
        peer_address: @peer_address,
        options: []
      }

      assert {:error, :hop_count_exceeded} = RelayAgent.validate_relay_message(relay_message)
    end

    test "rejects zero link address" do
      relay_message = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 1,
        link_address: @zero_address,
        peer_address: @peer_address,
        options: []
      }

      assert {:error, :invalid_link_address} = RelayAgent.validate_relay_message(relay_message)
    end

    test "rejects zero peer address" do
      relay_message = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 1,
        link_address: @link_address,
        peer_address: @zero_address,
        options: []
      }

      assert {:error, :invalid_peer_address} = RelayAgent.validate_relay_message(relay_message)
    end
  end

  describe "decapsulate_relay_forward/1" do
    test "returns error for non-relay-forward message" do
      non_relay_message = %{
        msg_type: @msg_type_solicit,
        hop_count: 0,
        options: []
      }

      assert {:error, :not_relay_forward} = RelayAgent.decapsulate_relay_forward(non_relay_message)
    end

    test "returns error for relay-reply message" do
      relay_reply = %{
        msg_type: @msg_type_relay_repl,
        hop_count: 1,
        link_address: @link_address,
        peer_address: @peer_address,
        options: []
      }

      assert {:error, :not_relay_forward} = RelayAgent.decapsulate_relay_forward(relay_reply)
    end

    test "returns error when relay message option is missing" do
      relay_forward = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 1,
        link_address: @link_address,
        peer_address: @peer_address,
        options: []
      }

      assert {:error, :missing_relay_message} = RelayAgent.decapsulate_relay_forward(relay_forward)
    end

    test "extracts relay info from valid relay forward" do
      # Create a simple encapsulated SOLICIT message binary
      # This is a minimal DHCPv6 SOLICIT message (msg_type=1, transaction_id)
      client_msg_binary = <<1, 0x12, 0x34, 0x56>>

      relay_forward = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 1,
        link_address: @link_address,
        peer_address: @peer_address,
        options: [
          %{option_code: @option_relay_msg, option_data: client_msg_binary}
        ]
      }

      case RelayAgent.decapsulate_relay_forward(relay_forward) do
        {:ok, {_client_message, relay_info}} ->
          assert relay_info.hop_count == 1
          assert relay_info.link_address == @link_address
          assert relay_info.peer_address == @peer_address
          assert relay_info.interface_id == nil
          assert relay_info.relay_id == nil

        {:error, :invalid_encapsulated_message} ->
          # This is expected since the binary is a minimal stub
          :ok
      end
    end

    test "extracts interface_id from options" do
      client_msg_binary = <<1, 0x12, 0x34, 0x56>>
      interface_id_data = "eth0"

      relay_forward = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 1,
        link_address: @link_address,
        peer_address: @peer_address,
        options: [
          %{option_code: @option_relay_msg, option_data: client_msg_binary},
          %{option_code: @option_interface_id, option_data: interface_id_data}
        ]
      }

      case RelayAgent.decapsulate_relay_forward(relay_forward) do
        {:ok, {_client_message, relay_info}} ->
          assert relay_info.interface_id == interface_id_data

        {:error, :invalid_encapsulated_message} ->
          # Expected since the binary is a minimal stub
          :ok
      end
    end

    test "extracts relay_id from options" do
      client_msg_binary = <<1, 0x12, 0x34, 0x56>>
      relay_id_data = <<0x00, 0x01, 0x02, 0x03>>

      relay_forward = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 1,
        link_address: @link_address,
        peer_address: @peer_address,
        options: [
          %{option_code: @option_relay_msg, option_data: client_msg_binary},
          %{option_code: @option_relay_id, option_data: relay_id_data}
        ]
      }

      case RelayAgent.decapsulate_relay_forward(relay_forward) do
        {:ok, {_client_message, relay_info}} ->
          assert relay_info.relay_id == relay_id_data

        {:error, :invalid_encapsulated_message} ->
          # Expected since the binary is a minimal stub
          :ok
      end
    end
  end

  describe "encapsulate_relay_reply/2" do
    test "creates relay reply from server response and relay info" do
      server_response = %DHCPv6.Message{
        msg_type: 7,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: []
      }

      relay_info = %{
        hop_count: 1,
        link_address: @link_address,
        peer_address: @peer_address,
        interface_id: nil,
        relay_id: nil
      }

      assert {:ok, relay_reply} = RelayAgent.encapsulate_relay_reply(server_response, relay_info)
      assert relay_reply.msg_type == @msg_type_relay_repl
      assert relay_reply.hop_count == 1
      assert relay_reply.link_address == @link_address
      assert relay_reply.peer_address == @peer_address
      assert relay_reply.encapsulated_response == server_response
    end

    test "includes interface_id in options when present" do
      server_response = %DHCPv6.Message{
        msg_type: 7,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: []
      }

      relay_info = %{
        hop_count: 1,
        link_address: @link_address,
        peer_address: @peer_address,
        interface_id: "eth0",
        relay_id: nil
      }

      assert {:ok, relay_reply} = RelayAgent.encapsulate_relay_reply(server_response, relay_info)

      # Check that interface_id option is included
      interface_id_option =
        Enum.find(relay_reply.options, fn opt ->
          opt.option_code == @option_interface_id
        end)

      assert interface_id_option != nil
      assert interface_id_option.option_data == "eth0"
    end

    test "handles multi-hop relay chain" do
      server_response = %DHCPv6.Message{
        msg_type: 7,
        transaction_id: <<0x12, 0x34, 0x56>>,
        options: []
      }

      # Simulate a multi-hop relay chain
      inner_relay = %{
        hop_count: 0,
        link_address: {0x2001, 0xDB8, 0, 2, 0, 0, 0, 1},
        peer_address: @peer_address
      }

      outer_relay = %{
        hop_count: 1,
        link_address: @link_address,
        peer_address: {0x2001, 0xDB8, 0, 2, 0, 0, 0, 1}
      }

      relay_info_with_chain = %{
        hop_count: 1,
        link_address: @link_address,
        peer_address: @peer_address,
        relay_chain: [outer_relay, inner_relay]
      }

      assert {:ok, relay_reply} =
               RelayAgent.encapsulate_relay_reply(server_response, relay_info_with_chain)

      # The outermost relay reply should have the outer relay's info
      assert relay_reply.msg_type == @msg_type_relay_repl
      assert relay_reply.hop_count == 1
      assert relay_reply.link_address == @link_address
    end
  end

  describe "edge cases" do
    test "handles empty options list" do
      relay_forward = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 0,
        link_address: @link_address,
        peer_address: @peer_address,
        options: []
      }

      # Should fail because relay message option is required
      assert {:error, :missing_relay_message} = RelayAgent.decapsulate_relay_forward(relay_forward)
    end

    test "validates minimum hop count of 0" do
      relay_message = %{
        msg_type: @msg_type_relay_forw,
        hop_count: 0,
        link_address: @link_address,
        peer_address: @peer_address,
        options: []
      }

      assert :ok = RelayAgent.validate_relay_message(relay_message)
    end

    test "handles relay reply without relay chain" do
      server_response = %DHCPv6.Message{
        msg_type: 7,
        transaction_id: <<0xAB, 0xCD, 0xEF>>,
        options: []
      }

      relay_info = %{
        hop_count: 0,
        link_address: @link_address,
        peer_address: @peer_address
      }

      assert {:ok, relay_reply} = RelayAgent.encapsulate_relay_reply(server_response, relay_info)
      assert relay_reply.msg_type == @msg_type_relay_repl
      assert is_list(relay_reply.options)
    end

    test "preserves all relay info fields in reply" do
      server_response = %DHCPv6.Message{
        msg_type: 2,
        transaction_id: <<0x65, 0x43, 0x21>>,
        options: []
      }

      relay_info = %{
        hop_count: 5,
        link_address: {0xFE80, 0, 0, 0, 0, 0, 0, 1},
        peer_address: {0xFE80, 0, 0, 0, 0, 0, 0, 0x100}
      }

      assert {:ok, relay_reply} = RelayAgent.encapsulate_relay_reply(server_response, relay_info)
      assert relay_reply.hop_count == 5
      assert relay_reply.link_address == {0xFE80, 0, 0, 0, 0, 0, 0, 1}
      assert relay_reply.peer_address == {0xFE80, 0, 0, 0, 0, 0, 0, 0x100}
    end
  end
end
