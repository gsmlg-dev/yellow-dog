defmodule YellowDog.Dhcpv4.Handler do
  @moduledoc """
  DHCPv4 message handler using the Abyss.Handler behaviour.

  Processes incoming DHCPv4 messages and implements the DHCP server logic
  for handling DHCPDISCOVER, DHCPOFFER, DHCPREQUEST, DHCPACK, and DHCPNAK
  messages. Emits telemetry events for monitoring and debugging.
  """

  use Abyss.Handler
  require Logger

  alias YellowDog.Dhcpv4.LeaseManager

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
        Logger.error(
          "Error handling DHCPv4 message from #{:inet.ntoa(ip)}:#{port}: #{inspect(e)}"
        )

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
      # BOOTREQUEST
      1 ->
        handle_boot_request(message, client_ip, client_port, state, start_time)

      # BOOTREPLY
      2 ->
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
        Logger.debug(
          "Received DHCP server message type: #{msg_type} (should not happen on server)"
        )

        {:continue, state}

      _ ->
        Logger.warning("DHCP message missing or unsupported message type option")
        {:continue, state}
    end
  end

  defp handle_dhcp_discover(message, client_ip, client_port, state, start_time) do
    Logger.info("DHCPDISCOVER from #{:inet.ntoa(client_ip)} (#{format_mac(message.chaddr)})")

    # Generate a DHCPOFFER response
    case create_dhcp_offer(message, client_ip) do
      nil ->
        Logger.warning("Failed to create DHCPOFFER for #{format_mac(message.chaddr)}")

      offer ->
        send_dhcp_response(offer, client_ip, client_port, state)
    end

    # Emit telemetry event
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :discover_handled],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    {:continue, state}
  end

  defp handle_dhcp_request(message, client_ip, client_port, state, start_time) do
    # Determine REQUEST state: SELECTING, INIT-REBOOT, RENEWING, or REBINDING
    request_state = determine_request_state(message)

    Logger.info(
      "DHCPREQUEST (#{request_state}) from #{:inet.ntoa(client_ip)} (#{format_mac(message.chaddr)})"
    )

    # Generate a DHCPACK or DHCPNAK response based on state
    case create_dhcp_ack(message, client_ip, request_state) do
      {:ok, ack} ->
        send_dhcp_response(ack, client_ip, client_port, state)

        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :request_ack],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: client_ip, client_mac: message.chaddr, state: request_state}
        )

      {:nak, reason} ->
        Logger.warning("Sending DHCPNAK to #{format_mac(message.chaddr)}: #{reason}")
        nak = build_dhcp_nak(message, reason)
        send_dhcp_response(nak, client_ip, client_port, state)

        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :request_nak],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{
            client_ip: client_ip,
            client_mac: message.chaddr,
            reason: reason,
            state: request_state
          }
        )
    end

    {:continue, state}
  end

  defp handle_dhcp_decline(message, client_ip, _client_port, state, start_time) do
    Logger.info("DHCPDECLINE from #{:inet.ntoa(client_ip)} (#{format_mac(message.chaddr)})")

    # Get the declined IP address
    declined_ip = get_requested_ip(message) || client_ip

    # Mark the IP as declined in LeaseManager
    LeaseManager.decline_ip(declined_ip, message.chaddr)

    # Emit telemetry event
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :decline_handled],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr, declined_ip: declined_ip}
    )

    {:continue, state}
  end

  defp handle_dhcp_release(message, client_ip, _client_port, state, start_time) do
    Logger.info("DHCPRELEASE from #{:inet.ntoa(client_ip)} (#{format_mac(message.chaddr)})")

    # Release the lease for this MAC address
    LeaseManager.release_lease(message.chaddr)

    # Emit telemetry event
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
    # Send to client port 68
    send_dhcp_response(ack, client_ip, 68, state)

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :inform_handled],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    {:continue, state}
  end

  defp create_dhcp_offer(discover, _client_ip) do
    # Extract hostname and client identifier from options if present
    hostname = get_hostname_from_options(discover.options)
    client_id = get_client_id_from_options(discover.options)

    # Try to allocate a lease from LeaseManager
    case LeaseManager.allocate_lease(discover.chaddr, nil, hostname, "default", client_id) do
      {:ok, lease} ->
        # Build DHCPOFFER with lease information
        build_dhcp_offer(discover, lease)

      {:error, :pool_exhausted} ->
        Logger.error("Cannot create DHCPOFFER: address pool exhausted")
        nil

      {:error, reason} ->
        Logger.error("Cannot create DHCPOFFER: #{inspect(reason)}")
        nil
    end
  end

  defp build_dhcp_offer(discover, lease) do
    # Get pool configuration for network parameters
    pool = get_pool_for_lease(lease)

    DHCPv4.Message.new()
    # BOOTREPLY = 2
    |> Map.put(:op, 2)
    |> Map.put(:htype, discover.htype)
    |> Map.put(:hlen, discover.hlen)
    |> Map.put(:xid, discover.xid)
    |> Map.put(:flags, discover.flags)
    |> Map.put(:ciaddr, 0)
    |> Map.put(:yiaddr, ip_tuple_to_integer(lease.ip_address))
    |> Map.put(:siaddr, ip_tuple_to_integer(pool.gateway))
    |> Map.put(:giaddr, ip_tuple_to_integer(discover.giaddr))
    |> Map.put(:chaddr, discover.chaddr)
    |> Map.put(:options, build_dhcp_options(2, pool, lease))
  end

  defp create_dhcp_ack(request, _client_ip, request_state) do
    # Extract hostname, requested IP, and client identifier
    hostname = get_hostname_from_options(request.options)
    client_id = get_client_id_from_options(request.options)
    server_id = get_server_id_from_options(request.options)

    # Get requested IP based on state
    requested_ip =
      case request_state do
        :renewing ->
          # For RENEWING, use ciaddr (client's current IP)
          integer_to_ip_tuple(request.ciaddr)

        :rebinding ->
          # For REBINDING, use ciaddr (client's current IP)
          integer_to_ip_tuple(request.ciaddr)

        _ ->
          # For SELECTING and INIT-REBOOT, use Requested IP Address option
          get_requested_ip(request)
      end

    # Validate server identifier if present (RFC 2131 Section 4.3.2)
    # For SELECTING state, server identifier is required and must match
    case validate_server_identifier(server_id, request_state) do
      :ok ->
        # Server ID is valid, proceed with lease allocation
        allocate_and_respond(request, requested_ip, hostname, client_id)

      {:error, :wrong_server} ->
        # Client is requesting from a different server, silently ignore
        Logger.debug("Ignoring REQUEST with non-matching server identifier")
        {:nak, "Wrong server identifier"}
    end
  end

  defp allocate_and_respond(request, requested_ip, hostname, client_id) do
    # Try to allocate/renew lease
    case LeaseManager.allocate_lease(request.chaddr, requested_ip, hostname, "default", client_id) do
      {:ok, lease} ->
        ack = build_dhcp_ack(request, lease)
        {:ok, ack}

      {:error, :pool_exhausted} ->
        Logger.error("Cannot create DHCPACK: address pool exhausted")
        {:nak, "Address pool exhausted"}

      {:error, :pool_not_found} ->
        Logger.error("Cannot create DHCPACK: pool not found")
        {:nak, "Invalid network or pool"}

      {:error, reason} ->
        Logger.error("Cannot create DHCPACK: #{inspect(reason)}")
        {:nak, "Lease allocation failed: #{inspect(reason)}"}
    end
  end

  defp build_dhcp_ack(request, lease) do
    # Get pool configuration for network parameters
    pool = get_pool_for_lease(lease)

    DHCPv4.Message.new()
    # BOOTREPLY = 2
    |> Map.put(:op, 2)
    |> Map.put(:htype, request.htype)
    |> Map.put(:hlen, request.hlen)
    |> Map.put(:xid, request.xid)
    |> Map.put(:flags, request.flags)
    |> Map.put(:ciaddr, ip_tuple_to_integer(request.ciaddr))
    |> Map.put(:yiaddr, ip_tuple_to_integer(lease.ip_address))
    |> Map.put(:siaddr, ip_tuple_to_integer(pool.gateway))
    |> Map.put(:giaddr, ip_tuple_to_integer(request.giaddr))
    |> Map.put(:chaddr, request.chaddr)
    |> Map.put(:options, build_dhcp_options(5, pool, lease))
  end

  defp build_dhcp_nak(request, reason) do
    # Get default pool for server identifier
    pool = get_default_pool()

    # Build DHCPNAK message according to RFC 2131
    DHCPv4.Message.new()
    # BOOTREPLY = 2
    |> Map.put(:op, 2)
    |> Map.put(:htype, request.htype)
    |> Map.put(:hlen, request.hlen)
    |> Map.put(:xid, request.xid)
    |> Map.put(:flags, request.flags)
    # RFC 2131: ciaddr, yiaddr, siaddr, and giaddr are set to 0
    |> Map.put(:ciaddr, 0)
    |> Map.put(:yiaddr, 0)
    |> Map.put(:siaddr, 0)
    |> Map.put(:giaddr, 0)
    |> Map.put(:chaddr, request.chaddr)
    |> Map.put(:options, build_dhcp_nak_options(pool, reason))
  end

  defp build_dhcp_nak_options(pool, reason) do
    # DHCPNAK options per RFC 2131
    base_options = [
      # Message type = 6 (DHCPNAK)
      %DHCPv4.Message.Option{type: 53, length: 1, value: <<6>>},
      # Server identifier
      %DHCPv4.Message.Option{type: 54, length: 4, value: ip_to_binary(pool.gateway)}
    ]

    # Add message option if reason is provided
    options_with_message =
      if reason && is_binary(reason) && byte_size(reason) > 0 do
        message_value = :binary.copy(reason)

        base_options ++
          [
            %DHCPv4.Message.Option{
              type: 56,
              length: byte_size(message_value),
              value: message_value
            }
          ]
      else
        base_options
      end

    # Add end option
    options_with_message ++ [%DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}]
  end

  defp create_dhcp_ack_inform(inform, client_ip) do
    # Build a DHCPACK response for DHCPINFORM (no address allocation)
    # Use first available pool for configuration parameters
    case LeaseManager.list_leases() do
      [] ->
        # No leases, use default pool
        pool = get_default_pool()
        build_dhcp_ack_inform(inform, client_ip, pool)

      [lease | _] ->
        # Use pool from an existing lease
        pool = get_pool_for_lease(lease)
        build_dhcp_ack_inform(inform, client_ip, pool)
    end
  end

  defp build_dhcp_ack_inform(inform, client_ip, pool) do
    DHCPv4.Message.new()
    # BOOTREPLY = 2
    |> Map.put(:op, 2)
    |> Map.put(:htype, inform.htype)
    |> Map.put(:hlen, inform.hlen)
    |> Map.put(:xid, inform.xid)
    |> Map.put(:flags, inform.flags)
    |> Map.put(:ciaddr, ip_tuple_to_integer(client_ip))
    |> Map.put(:siaddr, ip_tuple_to_integer(pool.gateway))
    |> Map.put(:giaddr, ip_tuple_to_integer(inform.giaddr))
    |> Map.put(:chaddr, inform.chaddr)
    |> Map.put(:options, [
      # DHCPACK = 5
      %DHCPv4.Message.Option{type: 53, length: 1, value: <<5>>},
      # server identifier
      %DHCPv4.Message.Option{type: 54, length: 4, value: ip_to_binary(pool.gateway)},
      # subnet mask
      %DHCPv4.Message.Option{type: 1, length: 4, value: ip_to_binary(pool.subnet_mask)},
      # router
      %DHCPv4.Message.Option{type: 3, length: 4, value: ip_to_binary(pool.gateway)},
      # DNS servers
      %DHCPv4.Message.Option{type: 6, length: 4, value: encode_dns_servers(pool.dns_servers)},
      # :end
      %DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}
    ])
  end

  defp send_dhcp_response(response, client_ip, client_port, state) do
    data = DHCP.Parameter.to_iodata(response)

    # Send response to client (port 67 for broadcast, 68 for unicast)
    response_port = if client_port == 67, do: 68, else: client_port

    case :gen_udp.send(state.socket, client_ip, response_port, data) do
      :ok ->
        Logger.debug("Sent DHCP response to #{:inet.ntoa(client_ip)}:#{response_port}")

      {:error, reason} ->
        Logger.error("Failed to send DHCP response: #{inspect(reason)}")
    end
  end

  # Helper functions for building DHCP responses

  defp build_dhcp_options(message_type, pool, lease) do
    lease_time_binary = <<lease.lease_time::32>>
    dns_servers_binary = encode_dns_servers(pool.dns_servers)

    base_options = [
      # Message type
      %DHCPv4.Message.Option{type: 53, length: 1, value: <<message_type>>},
      # Server identifier
      %DHCPv4.Message.Option{type: 54, length: 4, value: ip_to_binary(pool.gateway)},
      # Lease time
      %DHCPv4.Message.Option{type: 51, length: 4, value: lease_time_binary},
      # Subnet mask
      %DHCPv4.Message.Option{type: 1, length: 4, value: ip_to_binary(pool.subnet_mask)},
      # Router
      %DHCPv4.Message.Option{type: 3, length: 4, value: ip_to_binary(pool.gateway)},
      %DHCPv4.Message.Option{
        type: 6,
        length: byte_size(dns_servers_binary),
        # DNS servers
        value: dns_servers_binary
      }
    ]

    # Add domain name if present
    options_with_domain =
      case pool.domain_name do
        nil ->
          base_options

        "" ->
          base_options

        domain ->
          base_options ++
            [%DHCPv4.Message.Option{type: 15, length: byte_size(domain), value: domain}]
      end

    # Add end option
    options_with_domain ++ [%DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}]
  end

  defp get_pool_for_lease(_lease) do
    # For now, use the first pool from LeaseManager state
    # In a production system, you'd look up the pool by name from _lease.pool_name
    get_default_pool()
  end

  defp get_default_pool do
    # Return a default pool configuration
    # This should be retrieved from configuration or LeaseManager state
    %{
      name: "default",
      range_start: {192, 168, 1, 100},
      range_end: {192, 168, 1, 200},
      subnet_mask: {255, 255, 255, 0},
      gateway: {192, 168, 1, 1},
      dns_servers: [{192, 168, 1, 1}, {8, 8, 8, 8}],
      domain_name: "local",
      lease_time: 86400
    }
  end

  defp encode_dns_servers(dns_servers) do
    dns_servers
    |> Enum.map(&ip_to_binary/1)
    |> Enum.join()
  end

  defp get_hostname_from_options(options) do
    Enum.find_value(options, fn option ->
      # Option 12 is hostname
      if option.type == 12, do: option.value, else: nil
    end)
  end

  defp get_client_id_from_options(options) do
    Enum.find_value(options, fn option ->
      # Option 61 is client identifier
      if option.type == 61, do: option.value, else: nil
    end)
  end

  defp get_server_id_from_options(options) do
    Enum.find_value(options, fn option ->
      # Option 54 is server identifier
      if option.type == 54, do: option.value, else: nil
    end)
  end

  defp validate_server_identifier(nil, :renewing), do: :ok
  defp validate_server_identifier(nil, :rebinding), do: :ok
  defp validate_server_identifier(nil, _), do: :ok

  defp validate_server_identifier(server_id, _request_state) when is_binary(server_id) do
    # Get our server identifier (gateway IP from default pool)
    our_server_id = get_server_identifier()

    if server_id == our_server_id do
      :ok
    else
      {:error, :wrong_server}
    end
  end

  defp determine_request_state(request) do
    # Determine REQUEST state based on RFC 2131 Section 4.3.2
    server_id = get_server_id_from_options(request.options)
    requested_ip = get_requested_ip(request)
    ciaddr = request.ciaddr

    cond do
      # SELECTING: Server Identifier and Requested IP present, ciaddr is 0
      server_id != nil && requested_ip != nil && ciaddr == 0 ->
        :selecting

      # INIT-REBOOT: Requested IP present, no Server Identifier, ciaddr is 0
      requested_ip != nil && server_id == nil && ciaddr == 0 ->
        :init_reboot

      # RENEWING: ciaddr filled in, no Requested IP or Server Identifier
      ciaddr != 0 && requested_ip == nil && server_id == nil ->
        :renewing

      # REBINDING: ciaddr filled in, may have Requested IP but no Server Identifier
      ciaddr != 0 && server_id == nil ->
        :rebinding

      # Default to selecting if we can't determine
      true ->
        :selecting
    end
  end

  defp integer_to_ip_tuple(0), do: nil

  defp integer_to_ip_tuple(ip_int) when is_integer(ip_int) do
    a = div(ip_int, 256 * 256 * 256)
    b = div(rem(ip_int, 256 * 256 * 256), 256 * 256)
    c = div(rem(ip_int, 256 * 256), 256)
    d = rem(ip_int, 256)
    {a, b, c, d}
  end

  defp get_server_identifier do
    # Get the gateway IP from the default pool as our server identifier
    pool = get_default_pool()
    ip_to_binary(pool.gateway)
  end

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
  defp ip_to_binary(_), do: <<192, 168, 1, 1>>

  # Convert IP tuple to 32-bit integer for DHCPv4 message fields
  defp ip_tuple_to_integer({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    <<integer::32>> = <<a, b, c, d>>
    integer
  end

  defp ip_tuple_to_integer(integer) when is_integer(integer), do: integer
  defp ip_tuple_to_integer(_), do: 0

  defp format_mac(<<mac::binary-size(6)>>) do
    mac
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
  end

  defp format_mac(_), do: "unknown"
end
