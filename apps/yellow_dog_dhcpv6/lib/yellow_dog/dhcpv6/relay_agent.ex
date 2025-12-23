defmodule YellowDog.Dhcpv6.RelayAgent do
  @moduledoc """
  DHCPv6 Relay Agent support for multi-hop message forwarding.

  Handles RELAY-FORWARD and RELAY-REPLY messages, allowing the DHCPv6 server
  to communicate with clients on different network segments through relay agents.

  ## Relay Agent Flow

  ```
  Client ──▶ Relay Agent ──▶ DHCPv6 Server
               (RELAY-FORW)

  Client ◀── Relay Agent ◀── DHCPv6 Server
               (RELAY-REPL)
  ```

  ## Relay Message Format

  RELAY-FORWARD:
  - msg_type (1 byte): 12
  - hop_count (1 byte): Number of relay agents traversed
  - link_address (16 bytes): Address on the link where the client is located
  - peer_address (16 bytes): Address of the client or previous relay agent
  - options: Encapsulated client message and relay agent options

  RELAY-REPLY:
  - msg_type (1 byte): 13
  - hop_count (1 byte): Must match RELAY-FORWARD
  - link_address (16 bytes): Copied from RELAY-FORWARD
  - peer_address (16 bytes): Copied from RELAY-FORWARD
  - options: Encapsulated server response and relay agent options
  """

  @msg_type_relay_forw 12
  @msg_type_relay_repl 13

  @option_relay_msg 9
  @option_interface_id 18
  @option_relay_id 53

  @type ipv6_address ::
          {0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535}

  @type relay_message :: %{
          msg_type: 12 | 13,
          hop_count: byte(),
          link_address: ipv6_address(),
          peer_address: ipv6_address(),
          options: [map()],
          encapsulated_message: binary() | nil
        }

  @doc """
  Decapsulates a RELAY-FORWARD message to extract the original client message.

  ## Parameters
  - `relay_message` - The RELAY-FORWARD DHCPv6 message

  ## Returns
  - `{:ok, {client_message, relay_info}}` - Extracted client message and relay information
  - `{:error, reason}` - Failed to decapsulate
  """
  @spec decapsulate_relay_forward(map()) ::
          {:ok, {map(), relay_info :: map()}} | {:error, term()}
  def decapsulate_relay_forward(relay_message) do
    if relay_message.msg_type != @msg_type_relay_forw do
      {:error, :not_relay_forward}
    else
      # Extract relay information
      relay_info = %{
        hop_count: relay_message.hop_count,
        link_address: relay_message.link_address,
        peer_address: relay_message.peer_address,
        interface_id: extract_interface_id(relay_message.options),
        relay_id: extract_relay_id(relay_message.options)
      }

      # Extract encapsulated client message
      case extract_relay_message(relay_message.options) do
        {:ok, client_msg_binary} ->
          case DHCPv6.Message.from_iodata(client_msg_binary) do
            {:ok, client_message} ->
              # Check if this is a nested relay message (multi-hop)
              if client_message.msg_type == @msg_type_relay_forw do
                # Recursively decapsulate
                case decapsulate_relay_forward(client_message) do
                  {:ok, {inner_client_msg, inner_relay_info}} ->
                    # Build relay chain
                    relay_chain = [relay_info | List.wrap(inner_relay_info[:relay_chain] || [])]
                    combined_info = Map.put(inner_relay_info, :relay_chain, relay_chain)
                    {:ok, {inner_client_msg, combined_info}}

                  error ->
                    error
                end
              else
                {:ok, {client_message, relay_info}}
              end

            {:error, reason} ->
              :telemetry.execute(
                [:yellow_dog, :dhcpv6, :relay_agent, :parse_failed],
                %{count: 1},
                %{reason: inspect(reason)}
              )

              {:error, :invalid_encapsulated_message}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Encapsulates a server response into a RELAY-REPLY message.

  ## Parameters
  - `server_response` - The DHCPv6 response message from the server
  - `relay_info` - Relay information from the original RELAY-FORWARD

  ## Returns
  - `{:ok, relay_reply_message}` - Encapsulated RELAY-REPLY message
  - `{:error, reason}` - Failed to encapsulate
  """
  @spec encapsulate_relay_reply(map(), map()) :: {:ok, map()} | {:error, term()}
  def encapsulate_relay_reply(server_response, relay_info) do
    # Convert server response to binary
    response_binary = DHCP.Parameter.to_iodata(server_response) |> IO.iodata_to_binary()

    # Create relay message option
    relay_msg_option = %DHCPv6.Message.Option{
      option_code: @option_relay_msg,
      option_data: response_binary
    }

    # Build options list
    options = [relay_msg_option]

    # Add interface-id if present
    options =
      if relay_info[:interface_id] do
        interface_id_option = %DHCPv6.Message.Option{
          option_code: @option_interface_id,
          option_data: relay_info.interface_id
        }

        [interface_id_option | options]
      else
        options
      end

    # Check if this is part of a relay chain (multi-hop)
    relay_reply =
      if relay_info[:relay_chain] && length(relay_info.relay_chain) > 0 do
        # Build nested relay reply for multi-hop
        build_relay_chain_reply(server_response, relay_info.relay_chain)
      else
        # Single-hop relay reply
        # NOTE: This is a simplified implementation. Full relay support requires
        # proper RELAY-REPLY message structure from ex_dhcp library.
        # For now, we return a map with relay information.
        %{
          msg_type: @msg_type_relay_repl,
          hop_count: relay_info.hop_count,
          link_address: relay_info.link_address,
          peer_address: relay_info.peer_address,
          options: options,
          encapsulated_response: server_response
        }
      end

    {:ok, relay_reply}
  end

  @doc """
  Validates a relay message.

  ## Parameters
  - `relay_message` - The relay message to validate

  ## Returns
  - `:ok` if valid
  - `{:error, reason}` if invalid
  """
  @spec validate_relay_message(relay_message()) :: :ok | {:error, term()}
  def validate_relay_message(relay_message) do
    cond do
      relay_message.hop_count > 32 ->
        {:error, :hop_count_exceeded}

      relay_message.link_address == {0, 0, 0, 0, 0, 0, 0, 0} ->
        {:error, :invalid_link_address}

      relay_message.peer_address == {0, 0, 0, 0, 0, 0, 0, 0} ->
        {:error, :invalid_peer_address}

      true ->
        :ok
    end
  end

  ## Private Functions

  defp extract_interface_id(options) do
    case Enum.find(options, fn opt -> opt.option_code == @option_interface_id end) do
      nil -> nil
      option -> option.option_data
    end
  end

  defp extract_relay_id(options) do
    case Enum.find(options, fn opt -> opt.option_code == @option_relay_id end) do
      nil -> nil
      option -> option.option_data
    end
  end

  defp extract_relay_message(options) do
    case Enum.find(options, fn opt -> opt.option_code == @option_relay_msg end) do
      nil -> {:error, :missing_relay_message}
      option -> {:ok, option.option_data}
    end
  end

  defp build_relay_chain_reply(server_response, [relay_info | rest]) do
    if length(rest) > 0 do
      # Build inner relay reply first
      inner_reply = build_relay_chain_reply(server_response, rest)

      # Wrap in outer relay reply
      # NOTE: Simplified implementation - proper relay chain requires ex_dhcp support
      %{
        msg_type: @msg_type_relay_repl,
        hop_count: relay_info.hop_count,
        link_address: relay_info.link_address,
        peer_address: relay_info.peer_address,
        encapsulated_message: inner_reply
      }
    else
      # Outermost relay reply
      %{
        msg_type: @msg_type_relay_repl,
        hop_count: relay_info.hop_count,
        link_address: relay_info.link_address,
        peer_address: relay_info.peer_address,
        encapsulated_response: server_response
      }
    end
  end
end
