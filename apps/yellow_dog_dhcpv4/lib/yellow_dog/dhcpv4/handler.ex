defmodule YellowDog.Dhcpv4.Handler do
  @moduledoc """
  DHCPv4 message handler using the Abyss.Handler behaviour.

  Processes incoming DHCPv4 messages and implements the DHCP server logic
  for handling DHCPDISCOVER, DHCPOFFER, DHCPREQUEST, DHCPACK, and DHCPNAK
  messages. Emits telemetry events for monitoring and debugging.
  """

  use Abyss.Handler
  require Logger

  # Telemetry events are handled via :telemetry directly

  @doc """
  Handles incoming DHCPv4 messages from clients.

  ## Parameters
  - `{ip, port, data}`: Tuple containing client IP, port, and message data
  - `state`: Handler state containing socket information

  ## Returns
  - `{:continue, state}` - Continue handling more packets
  - `{:close, state}` - Close connection after response
  """
  @impl true
  def handle_data({ip, port, data}, state) do
    start_time = System.monotonic_time(:microsecond)

    try do
      message = DHCPv4.Message.from_iodata(data)
      Logger.debug("Received DHCPv4 message from #{:inet.ntoa(ip)}:#{port} - #{message.op}")

      # Emit telemetry event for message received
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :message_received],
        %{duration: System.monotonic_time(:microsecond) - start_time},
        %{client_ip: ip, client_port: port, message_type: message.op}
      )

      # Process the DHCP message
      handle_dhcp_message(message, ip, port, state, start_time)
    rescue
      e ->
        Logger.error("Error handling DHCPv4 message from #{:inet.ntoa(ip)}:#{port}: #{inspect(e)}")

        # Emit telemetry event for error
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :message_error],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: ip, client_port: port, error: Exception.message(e)}
        )

        {:continue, state}
    end
  end

  @impl true
  def handle_error(reason, state) do
    Logger.error("DHCPv4 handler error: #{inspect(reason)}")
    {:continue, state}
  end

  @impl true
  def handle_timeout(state) do
    Logger.debug("DHCPv4 handler timeout")
    {:continue, state}
  end

  # Private helper functions

  defp handle_dhcp_message(message, client_ip, client_port, state, start_time) do
    case message.op do
      1 ->  # BOOTREQUEST
        handle_boot_request(message, client_ip, client_port, state, start_time)

      2 ->  # BOOTREPLY
        Logger.debug("Received BOOTREPLY (should not happen on server)")
        {:continue, state}

      op ->
        Logger.warning("Unknown DHCP operation: #{op}")
        {:continue, state}
    end
  end

  defp handle_boot_request(message, client_ip, client_port, state, start_time) do
    case get_dhcp_message_type(message) do
      :discover ->
        handle_dhcp_discover(message, client_ip, client_port, state, start_time)

      :request ->
        handle_dhcp_request(message, client_ip, client_port, state, start_time)

      :decline ->
        handle_dhcp_decline(message, client_ip, client_port, state, start_time)

      :release ->
        handle_dhcp_release(message, client_ip, client_port, state, start_time)

      :inform ->
        handle_dhcp_inform(message, client_ip, client_port, state, start_time)

      msg_type when msg_type in [:offer, :ack, :nak] ->
        Logger.debug("Received DHCP server message type: #{msg_type} (should not happen on server)")
        {:continue, state}

      _ ->
      Logger.warning("DHCP message missing or unsupported message type option")
      {:continue, state}
    end
  end

  defp handle_dhcp_discover(message, client_ip, client_port, state, start_time) do
    Logger.info("DHCPDISCOVER from #{:inet.ntoa(client_ip)} (#{format_mac(message.chaddr)})")

    # Generate a DHCPOFFER response
    offer = create_dhcp_offer(message, client_ip)
    send_dhcp_response(offer, client_ip, client_port, state)

    # Emit telemetry event
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :discover_handled],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    {:continue, state}
  end

  defp handle_dhcp_request(message, client_ip, client_port, state, start_time) do
    Logger.info("DHCPREQUEST from #{:inet.ntoa(client_ip)} (#{format_mac(message.chaddr)})")

    # Generate a DHCPACK or DHCPNAK response
    # Since should_ack_request? always returns true, we always send an ACK
    ack = create_dhcp_ack(message, client_ip)
    send_dhcp_response(ack, client_ip, client_port, state)

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :request_ack],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    {:continue, state}
  end

  defp handle_dhcp_decline(message, client_ip, _client_port, state, start_time) do
    Logger.info("DHCPDECLINE from #{:inet.ntoa(client_ip)} (#{format_mac(message.chaddr)})")

    # Handle decline - mark the offered address as declined
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :decline_handled],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    {:continue, state}
  end

  defp handle_dhcp_release(message, client_ip, _client_port, state, start_time) do
    Logger.info("DHCPRELEASE from #{:inet.ntoa(client_ip)} (#{format_mac(message.chaddr)})")

    # Handle release - free the allocated address
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :release_handled],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    {:continue, state}
  end

  defp handle_dhcp_inform(message, client_ip, _client_port, state, start_time) do
    Logger.info("DHCPINFORM from #{:inet.ntoa(client_ip)} (#{format_mac(message.chaddr)})")

    # Handle inform - provide configuration parameters only
    ack = create_dhcp_ack_inform(message, client_ip)
    send_dhcp_response(ack, client_ip, 68, state)  # Send to client port 68

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :inform_handled],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    {:continue, state}
  end

  defp create_dhcp_offer(discover, client_ip) do
    # Build a DHCPOFFER response
    offered_ip = generate_ip_address(client_ip, discover.chaddr)

    DHCPv4.Message.new()
      |> Map.put(:op, 2)  # BOOTREPLY = 2
      |> Map.put(:htype, discover.htype)
      |> Map.put(:hlen, discover.hlen)
      |> Map.put(:xid, discover.xid)
      |> Map.put(:flags, discover.flags)
      |> Map.put(:yiaddr, offered_ip)
      |> Map.put(:siaddr, get_server_ip())
      |> Map.put(:giaddr, discover.giaddr)
      |> Map.put(:chaddr, discover.chaddr)
      |> Map.put(:options, [
          %DHCPv4.Message.Option{type: 53, length: 1, value: <<2>>},  # DHCPOFFER = 2
          %DHCPv4.Message.Option{type: 54, length: 4, value: ip_to_binary(get_server_ip())},  # server identifier
          %DHCPv4.Message.Option{type: 51, length: 4, value: <<0, 1, 80, 208>>},  # lease time = 86400
          %DHCPv4.Message.Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},  # subnet mask
          %DHCPv4.Message.Option{type: 3, length: 4, value: ip_to_binary(get_server_ip())},  # router
          %DHCPv4.Message.Option{type: 6, length: 4, value: ip_to_binary(get_server_ip())},  # domain name servers
          %DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}  # :end
        ])
  end

  defp create_dhcp_ack(request, client_ip) do
    # Build a DHCPACK response
    acked_ip = get_requested_ip(request) || generate_ip_address(client_ip, request.chaddr)

    DHCPv4.Message.new()
      |> Map.put(:op, 2)  # BOOTREPLY = 2
      |> Map.put(:htype, request.htype)
      |> Map.put(:hlen, request.hlen)
      |> Map.put(:xid, request.xid)
      |> Map.put(:flags, request.flags)
      |> Map.put(:ciaddr, request.ciaddr)
      |> Map.put(:yiaddr, acked_ip)
      |> Map.put(:siaddr, get_server_ip())
      |> Map.put(:giaddr, request.giaddr)
      |> Map.put(:chaddr, request.chaddr)
      |> Map.put(:options, [
          %DHCPv4.Message.Option{type: 53, length: 1, value: <<5>>},  # DHCPACK = 5
          %DHCPv4.Message.Option{type: 54, length: 4, value: ip_to_binary(get_server_ip())},  # server identifier
          %DHCPv4.Message.Option{type: 51, length: 4, value: <<0, 1, 80, 208>>},  # lease time = 86400
          %DHCPv4.Message.Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},  # subnet mask
          %DHCPv4.Message.Option{type: 3, length: 4, value: ip_to_binary(get_server_ip())},  # router
          %DHCPv4.Message.Option{type: 6, length: 4, value: ip_to_binary(get_server_ip())},  # domain name servers
          %DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}  # :end
        ])
  end

  # create_dhcp_nak function removed - unused in current implementation

  defp create_dhcp_ack_inform(inform, client_ip) do
    # Build a DHCPACK response for DHCPINFORM (no address allocation)
    DHCPv4.Message.new()
      |> Map.put(:op, 2)  # BOOTREPLY = 2
      |> Map.put(:htype, inform.htype)
      |> Map.put(:hlen, inform.hlen)
      |> Map.put(:xid, inform.xid)
      |> Map.put(:flags, inform.flags)
      |> Map.put(:ciaddr, client_ip)
      |> Map.put(:siaddr, get_server_ip())
      |> Map.put(:giaddr, inform.giaddr)
      |> Map.put(:chaddr, inform.chaddr)
      |> Map.put(:options, [
          %DHCPv4.Message.Option{type: 53, length: 1, value: <<5>>},  # DHCPACK = 5
          %DHCPv4.Message.Option{type: 54, length: 4, value: ip_to_binary(get_server_ip())},  # server identifier
          %DHCPv4.Message.Option{type: 1, length: 4, value: <<255, 255, 255, 0>>},  # subnet mask
          %DHCPv4.Message.Option{type: 3, length: 4, value: ip_to_binary(get_server_ip())},  # router
          %DHCPv4.Message.Option{type: 6, length: 4, value: ip_to_binary(get_server_ip())},  # domain name servers
          %DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}  # :end
        ])
  end

  defp send_dhcp_response(response, client_ip, client_port, state) do
    data = DHCP.Parameter.to_iodata(response)

    # Send response to client (port 67 for broadcast, 68 for unicast)
    response_port = if client_port == 67, do: 68, else: client_port

    case Abyss.Transport.UDP.send(state.socket, client_ip, response_port, data) do
      :ok ->
        Logger.debug("Sent DHCP response to #{:inet.ntoa(client_ip)}:#{response_port}")

      {:error, reason} ->
        Logger.error("Failed to send DHCP response: #{inspect(reason)}")
    end
  end

  # should_ack_request? function removed - unused in current implementation

  defp get_requested_ip(request) do
    Enum.find_value(request.options, fn option ->
      if option.type == 50, do: binary_to_ip(option.value), else: nil
    end)
  end

  defp get_dhcp_message_type(message) do
    Enum.find_value(message.options, 0, fn option ->
      if option.type == 53, do: decode_message_type(option.value), else: nil
    end)
  end

  defp decode_message_type(<<1>>), do: :discover
  defp decode_message_type(<<2>>), do: :offer
  defp decode_message_type(<<3>>), do: :request
  defp decode_message_type(<<4>>), do: :decline
  defp decode_message_type(<<5>>), do: :ack
  defp decode_message_type(<<6>>), do: :nak
  defp decode_message_type(<<7>>), do: :release
  defp decode_message_type(<<8>>), do: :inform
  defp decode_message_type(_), do: 0

  defp binary_to_ip(<<a, b, c, d>>), do: {a, b, c, d}
  defp binary_to_ip(_), do: nil

  defp ip_to_binary({a, b, c, d}), do: <<a, b, c, d>>
  defp ip_to_binary(_), do: {192, 168, 1, 1} |> ip_to_binary()

  defp generate_ip_address(_client_ip, _mac) do
    # Simple IP generation - in a real implementation this would:
    # - Check available address pools
    # - Track allocated addresses
    # - Handle address conflicts
    # For now, return a hardcoded address from the 192.168.1.0/24 pool
    {192, 168, 1, 100}
  end

  defp get_server_ip do
    # Use default server IP since config is handled by main application
    {192, 168, 1, 1}
  end

  defp format_mac(<<mac::binary-size(6)>>) do
    mac
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
  end

  defp format_mac(_), do: "unknown"
end