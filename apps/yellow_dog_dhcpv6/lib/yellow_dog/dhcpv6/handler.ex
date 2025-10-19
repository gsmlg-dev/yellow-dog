defmodule YellowDog.Dhcpv6.Handler do
  @moduledoc """
  DHCPv6 message handler implementing the Abyss.Handler behaviour.

  Processes DHCPv6 messages including SOLICIT, ADVERTISE, REQUEST,
  REPLY, and other DHCPv6 protocol messages. Handles client identification
  via DUID (DHCP Unique Identifier) and supports IPv6 multicast.
  """

  require Logger

  # DHCPv6 constants (available for future use if needed)
  # @dhcpv6_multicast_address {0xFF02, 0, 0, 0, 0, 0, 1, 2}
  # @dhcpv6_server_port 547
  # @dhcpv6_client_port 546

  @doc """
  Handles incoming DHCPv6 data from clients.

  ## Parameters
  - `data` - Tuple containing {client_ip, client_port, message_data}
  - `state` - Handler state (contains socket information)

  ## Returns
  - `{:continue, state}` - Continue processing (standard response)
  """
  def handle_data({client_ip, client_port, data}, state) do
    try do
      case DHCPv6.Message.from_iodata(data) do
        {:ok, message} ->
          handle_dhcpv6_message(message, client_ip, client_port, state)

        {:error, reason} ->
          Logger.warning("Failed to parse DHCPv6 message from #{format_ip(client_ip)}:#{client_port}: #{inspect(reason)}")
          {:continue, state}
      end
    rescue
      error ->
        Logger.error("Error handling DHCPv6 message from #{format_ip(client_ip)}:#{client_port}: #{inspect(error)}")
        {:continue, state}
    end
  end

  @doc """
  Handles handler errors (implements Abyss.Handler callback).

  ## Parameters
  - `error` - The error that occurred
  - `state` - Current handler state

  ## Returns
  - `{:continue, state}` - Continue processing
  """
  def handle_error(error, state) do
    Logger.error("DHCPv6 handler error: #{inspect(error)}")
    {:continue, state}
  end

  @doc """
  Handles handler timeouts (implements Abyss.Handler callback).

  ## Parameters
  - `state` - Current handler state

  ## Returns
  - `{:continue, state}` - Continue processing
  """
  def handle_timeout(state) do
    Logger.debug("DHCPv6 handler timeout")
    {:continue, state}
  end

  # Private functions for handling specific DHCPv6 message types

  defp handle_dhcpv6_message(message, client_ip, client_port, state) do
    case message.msg_type do
      1 -> # SOLICIT
        handle_solicit(message, client_ip, client_port, state)

      3 -> # REQUEST
        handle_request(message, client_ip, client_port, state)

      5 -> # RENEW
        handle_renew(message, client_ip, client_port, state)

      6 -> # REBIND
        handle_rebind(message, client_ip, client_port, state)

      8 -> # RELEASE
        handle_release(message, client_ip, client_port, state)

      9 -> # DECLINE
        handle_decline(message, client_ip, client_port, state)

      11 -> # INFORMATION-REQUEST
        handle_inform(message, client_ip, client_port, state)

      12 -> # RELAY-FORW
        handle_relay_forward(message, client_ip, client_port, state)

      13 -> # RELAY-REPL
        handle_relay_reply(message, client_ip, client_port, state)

      _ ->
        Logger.warning("Unknown DHCPv6 message type: #{message.msg_type} from #{format_ip(client_ip)}:#{client_port}")
        {:continue, state}
    end
  end

  defp handle_solicit(message, client_ip, client_port, state) do
    Logger.info("DHCPv6 SOLICIT from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})")

    # TODO: Implement DHCPv6 SOLICIT handling
    # - Parse client DUID
    # - Check for rapid commit option
    # - Generate ADVERTISE message
    # - Send response

    {:continue, state}
  end

  defp handle_request(message, client_ip, client_port, state) do
    Logger.info("DHCPv6 REQUEST from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})")

    # TODO: Implement DHCPv6 REQUEST handling
    # - Parse client DUID and server DUID
    # - Validate requested addresses/prefixes
    # - Generate REPLY message with assignment
    # - Send response

    {:continue, state}
  end

  defp handle_renew(message, client_ip, client_port, state) do
    Logger.info("DHCPv6 RENEW from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})")

    # TODO: Implement DHCPv6 RENEW handling
    # - Validate lease renewal
    # - Extend lease time if valid
    # - Send REPLY with updated lease

    {:continue, state}
  end

  defp handle_rebind(message, client_ip, client_port, state) do
    Logger.info("DHCPv6 REBIND from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})")

    # TODO: Implement DHCPv6 REBIND handling
    # - Handle rebind when server communication failed
    # - Validate and extend lease if possible
    # - Send appropriate REPLY

    {:continue, state}
  end

  defp handle_release(message, client_ip, client_port, state) do
    Logger.info("DHCPv6 RELEASE from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})")

    # TODO: Implement DHCPv6 RELEASE handling
    # - Parse client DUID and addresses to release
    # - Mark addresses as available
    # - Send REPLY confirmation

    {:continue, state}
  end

  defp handle_decline(message, client_ip, client_port, state) do
    Logger.info("DHCPv6 DECLINE from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})")

    # TODO: Implement DHCPv6 DECLINE handling
    # - Mark declined addresses as unusable
    # - Send REPLY confirmation

    {:continue, state}
  end

  defp handle_inform(message, client_ip, client_port, state) do
    Logger.info("DHCPv6 INFORM from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})")

    # TODO: Implement DHCPv6 INFORM handling
    # - Provide configuration information without address assignment
    # - Send REPLY with config options

    {:continue, state}
  end

  defp handle_relay_forward(_message, client_ip, client_port, state) do
    Logger.info("DHCPv6 RELAY-FORWARD from #{format_ip(client_ip)}:#{client_port}")

    # TODO: Implement DHCPv6 RELAY-FORWARD handling
    # - Handle relayed messages from other DHCPv6 servers
    # - Forward to appropriate server or generate reply

    {:continue, state}
  end

  defp handle_relay_reply(_message, client_ip, client_port, state) do
    Logger.info("DHCPv6 RELAY-REPLY from #{format_ip(client_ip)}:#{client_port}")

    # TODO: Implement DHCPv6 RELAY-REPLY handling
    # - Handle relayed reply messages
    # - Forward to appropriate client

    {:continue, state}
  end

  # Helper functions

  defp format_client_duid(message) do
    # Find client DUID option (option code 1) in the message options
    case Enum.find(message.options, fn option -> option.option_code == 1 end) do
      nil ->
        "unknown_duid"
      option ->
        "DUID#{:erlang.phash2(option.option_data) |> Integer.to_string(16) |> String.upcase()}"
    end
  end

  defp format_ip({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_ip({a, b, c, d, e, f, g, h}) do
    # Format IPv6 address as compressed string
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))

    # Basic compression - replace longest sequence of 0s with ::
    hex_str = Enum.join(hex_parts, ":")

    # Simple compression for common cases
    hex_str
    |> String.replace(":0:0:0:0:0:0:0:0", "::")
    |> String.replace(":0:0:0:0:0:0:0", "::")
    |> String.replace(":0:0:0:0:0:0", "::")
    |> String.replace(":0:0:0:0:0", "::")
    |> String.replace(":0:0:0:0", "::")
    |> String.replace(":0:0:0", "::")
    |> String.replace(":0:0", "::")
  end
end