defmodule YellowDog.Dhcpv4.Handler do
  @moduledoc """
  DHCPv4 message handler using the Abyss.Handler behaviour.

  Processes incoming DHCPv4 messages and implements the DHCP server logic
  for handling DHCPDISCOVER, DHCPOFFER, DHCPREQUEST, DHCPACK, and DHCPNAK
  messages. Emits telemetry events for monitoring and debugging.

  Includes rate limiting to prevent pool exhaustion and DoS attacks.
  """

  use Abyss.Handler

  alias YellowDog.Dhcpv4.{
    ACL,
    ConflictResolver,
    CustomOptions,
    LeaseManager,
    OptionParser,
    RateLimiter
  }

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

    # Apply rate limiting to prevent DoS and pool exhaustion attacks
    case RateLimiter.check_rate(ip) do
      :ok ->
        process_message(ip, port, data, state, start_time)

      {:error, :rate_limited} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :message, :rate_limited],
          %{count: 1},
          %{client_ip: ip, client_port: port}
        )

        {:continue, state}
    end
  end

  defp process_message(ip, port, data, state, start_time) do
    try do
      message = DHCPv4.Message.from_iodata(data)

      # Emit telemetry event for message received
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :message_received],
        %{duration: System.monotonic_time(:microsecond) - start_time},
        %{client_ip: ip, client_port: port, message_type: message.op}
      )

      # Process the DHCP message
      handle_dhcp_message(message, ip, port, state, start_time)
    rescue
      e in [ArgumentError, MatchError, FunctionClauseError, RuntimeError] ->
        # Emit telemetry event for error
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :message, :error],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: ip, client_port: port, error: Exception.message(e)}
        )

        {:continue, state}
    end
  end

  @impl true
  def handle_error(reason, state) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :handler, :error],
      %{count: 1},
      %{reason: inspect(reason)}
    )

    {:continue, state}
  end

  @impl true
  def handle_timeout(state) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :handler, :timeout],
      %{count: 1},
      %{}
    )

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
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :message, :unexpected],
          %{count: 1},
          %{message_type: :bootreply, reason: "should not happen on server"}
        )

        {:continue, state}

      op ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :message, :unknown],
          %{count: 1},
          %{operation: op}
        )

        {:continue, state}
    end
  end

  defp handle_boot_request(message, client_ip, client_port, state, start_time) do
    # Single-pass option extraction for better performance
    # Extracts all commonly needed options in O(n) instead of O(n*m)
    parsed_options = OptionParser.extract_common(message.options)

    case parsed_options.message_type do
      :discover ->
        handle_dhcp_discover(message, parsed_options, client_ip, client_port, state, start_time)

      :request ->
        handle_dhcp_request(message, parsed_options, client_ip, client_port, state, start_time)

      :decline ->
        handle_dhcp_decline(message, parsed_options, client_ip, client_port, state, start_time)

      :release ->
        handle_dhcp_release(message, client_ip, client_port, state, start_time)

      :inform ->
        handle_dhcp_inform(message, client_ip, client_port, state, start_time)

      msg_type when msg_type in [:offer, :ack, :nak] ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :message, :unexpected],
          %{count: 1},
          %{message_type: msg_type, reason: "should not happen on server"}
        )

        {:continue, state}

      _ ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :message, :unsupported],
          %{count: 1},
          %{reason: "missing or unsupported message type option"}
        )

        {:continue, state}
    end
  end

  defp handle_dhcp_discover(message, parsed_opts, client_ip, client_port, state, start_time) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :lease, :requested],
      %{count: 1},
      %{client_ip: client_ip, client_mac: message.chaddr, message_type: :discover}
    )

    # Build client info for ACL evaluation (using pre-parsed options)
    client_info = OptionParser.build_client_info(message, parsed_opts)

    # Evaluate ACL rules (FR3)
    acl_rules = get_acl_rules()
    acl_result = ACL.evaluate(acl_rules, client_info)

    case acl_result do
      {:deny, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :acl, :denied],
          %{count: 1},
          %{client_mac: message.chaddr, reason: reason}
        )

        # Don't send a response - silently ignore denied clients
        :ok

      {:allow, target_pool} ->
        # Determine pool name from ACL or default
        pool_name = target_pool || "default"

        # Generate a DHCPOFFER response (no custom option set for allow action)
        # Pass pre-parsed options for efficiency
        case create_dhcp_offer(message, parsed_opts, pool_name, nil) do
          nil ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :offer, :failed],
              %{count: 1},
              %{client_mac: message.chaddr, reason: "could not create offer"}
            )

          offer ->
            send_dhcp_response(offer, client_ip, client_port, state)
        end

      {:custom_options, option_set_name} ->
        # Apply custom options and allow the request
        # Pass pre-parsed options for efficiency
        case create_dhcp_offer(message, parsed_opts, "default", option_set_name) do
          nil ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :offer, :failed],
              %{count: 1},
              %{client_mac: message.chaddr, reason: "could not create offer with custom options"}
            )

          offer ->
            send_dhcp_response(offer, client_ip, client_port, state)
        end
    end

    # Emit telemetry event
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :discover_handled],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    {:continue, state}
  end

  defp handle_dhcp_request(message, parsed_opts, client_ip, client_port, state, start_time) do
    # Determine REQUEST state using pre-parsed options
    request_state = determine_request_state_fast(message, parsed_opts)

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :lease, :requested],
      %{count: 1},
      %{
        client_ip: client_ip,
        client_mac: message.chaddr,
        message_type: :request,
        state: request_state
      }
    )

    # Generate a DHCPACK or DHCPNAK response based on state (using pre-parsed options)
    case create_dhcp_ack(message, parsed_opts, client_ip, request_state) do
      {:ok, ack} ->
        send_dhcp_response(ack, client_ip, client_port, state)

        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease, :granted],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: client_ip, client_mac: message.chaddr, state: request_state}
        )

      {:nak, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease, :rejected],
          %{count: 1},
          %{client_mac: message.chaddr, reason: reason, state: request_state}
        )

        nak = build_dhcp_nak(message, reason)
        send_dhcp_response(nak, client_ip, client_port, state)
    end

    {:continue, state}
  end

  defp handle_dhcp_decline(message, parsed_opts, client_ip, _client_port, state, start_time) do
    # Get the declined IP address from pre-parsed options
    declined_ip = parsed_opts.requested_ip || client_ip

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :lease, :declined],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr, declined_ip: declined_ip}
    )

    # Use ConflictResolver for conflict detection and auto-reassignment (FR2.4)
    # ConflictResolver will:
    # 1. Quarantine the declined IP
    # 2. Attempt to allocate a new address for the client
    # 3. Log the conflict with client details
    case ConflictResolver.handle_conflict(declined_ip, message.chaddr, "default") do
      {:ok, new_ip} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :conflict, :reassigned],
          %{count: 1},
          %{
            client_mac: message.chaddr,
            declined_ip: declined_ip,
            new_ip: new_ip
          }
        )

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :conflict, :reassignment_failed],
          %{count: 1},
          %{
            client_mac: message.chaddr,
            declined_ip: declined_ip,
            reason: inspect(reason)
          }
        )
    end

    {:continue, state}
  end

  defp handle_dhcp_release(message, client_ip, _client_port, state, start_time) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :lease, :released],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    # Release the lease for this MAC address
    LeaseManager.release_lease(message.chaddr)

    {:continue, state}
  end

  defp handle_dhcp_inform(message, client_ip, _client_port, state, start_time) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :inform, :received],
      %{count: 1},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    # Handle inform - provide configuration parameters only
    ack = create_dhcp_ack_inform(message, client_ip)
    # Send to client port 68
    send_dhcp_response(ack, client_ip, 68, state)

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :inform, :handled],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip, client_mac: message.chaddr}
    )

    {:continue, state}
  end

  defp create_dhcp_offer(discover, parsed_opts, pool_name, option_set_name) do
    # Use pre-parsed hostname and client identifier for efficiency
    hostname = parsed_opts.hostname
    client_id = parsed_opts.client_id

    # Try to allocate a lease from LeaseManager
    case LeaseManager.allocate_lease(discover.chaddr, nil, hostname, pool_name, client_id) do
      {:ok, lease} ->
        # Build DHCPOFFER with lease information and custom options
        build_dhcp_offer(discover, lease, option_set_name)

      {:error, :pool_exhausted} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :pool, :exhausted],
          %{count: 1},
          %{client_mac: discover.chaddr, operation: :offer}
        )

        nil

      {:error, :pool_limit_exceeded} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :pool, :limit_exceeded],
          %{count: 1},
          %{client_mac: discover.chaddr, pool: pool_name, operation: :offer}
        )

        nil

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :offer, :error],
          %{count: 1},
          %{client_mac: discover.chaddr, reason: inspect(reason)}
        )

        nil
    end
  end

  defp build_dhcp_offer(discover, lease, option_set_name) do
    # Get pool configuration for network parameters
    pool = get_pool_for_lease(lease)

    # Build context for custom options template substitution (FR4.3)
    # Use hostname from lease (already stored during allocation)
    context = %{
      client_mac: discover.chaddr,
      client_hostname: lease.hostname,
      lease_address: lease.ip_address,
      pool_name: lease.pool_name
    }

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
    |> Map.put(:options, build_dhcp_options(2, pool, lease, context, option_set_name))
  end

  defp create_dhcp_ack(request, parsed_opts, _client_ip, request_state) do
    # Use pre-parsed options for efficiency
    hostname = parsed_opts.hostname
    client_id = parsed_opts.client_id
    server_id = parsed_opts.server_id

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
          # For SELECTING and INIT-REBOOT, use pre-parsed Requested IP Address
          parsed_opts.requested_ip
      end

    # Validate server identifier if present (RFC 2131 Section 4.3.2)
    # For SELECTING state, server identifier is required and must match
    case validate_server_identifier(server_id, request_state) do
      :ok ->
        # Server ID is valid, proceed with lease allocation
        allocate_and_respond(request, requested_ip, hostname, client_id)

      {:error, :wrong_server} ->
        # Client is requesting from a different server, silently ignore
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :request, :ignored],
          %{count: 1},
          %{client_mac: request.chaddr, reason: "non-matching server identifier"}
        )

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
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :pool, :exhausted],
          %{count: 1},
          %{client_mac: request.chaddr, operation: :ack}
        )

        {:nak, "Address pool exhausted"}

      {:error, :pool_not_found} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :pool, :not_found],
          %{count: 1},
          %{client_mac: request.chaddr}
        )

        {:nak, "Invalid network or pool"}

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :ack, :error],
          %{count: 1},
          %{client_mac: request.chaddr, reason: inspect(reason)}
        )

        {:nak, "Lease allocation failed: #{inspect(reason)}"}
    end
  end

  defp build_dhcp_ack(request, lease) do
    # Get pool configuration for network parameters
    pool = get_pool_for_lease(lease)

    # Build context for template substitution
    # Use hostname from lease (already stored during allocation)
    context = %{
      client_mac: request.chaddr,
      client_hostname: lease.hostname,
      lease_address: lease.ip_address,
      pool_name: lease.pool_name
    }

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
    |> Map.put(:options, build_dhcp_options(5, pool, lease, context))
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
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :response, :sent],
          %{count: 1, bytes: IO.iodata_length(data)},
          %{client_ip: client_ip, client_port: response_port}
        )

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :response, :error],
          %{count: 1},
          %{client_ip: client_ip, client_port: response_port, reason: inspect(reason)}
        )
    end
  end

  # Helper functions for building DHCP responses

  defp build_dhcp_options(message_type, pool, lease, context, option_set_name \\ nil) do
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

    # Apply custom options if option_set_name is specified (FR4)
    options_with_custom =
      if option_set_name do
        apply_custom_options(options_with_domain, option_set_name, context)
      else
        options_with_domain
      end

    # Add end option
    options_with_custom ++ [%DHCPv4.Message.Option{type: 255, length: 0, value: <<>>}]
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

  # Note: Option extraction functions moved to OptionParser for single-pass efficiency
  # Legacy functions removed to avoid code duplication

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

  # Optimized version using pre-parsed options
  defp determine_request_state_fast(request, parsed_opts) do
    # Determine REQUEST state based on RFC 2131 Section 4.3.2
    # Uses pre-parsed options for efficiency
    server_id = parsed_opts.server_id
    requested_ip = parsed_opts.requested_ip
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

  defp ip_to_binary({a, b, c, d}), do: <<a, b, c, d>>

  defp ip_to_binary(nil) do
    # Log warning for nil IP addresses - this indicates a configuration issue
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :config, :warning],
      %{count: 1},
      %{issue: "ip_to_binary called with nil, using fallback"}
    )

    <<0, 0, 0, 0>>
  end

  defp ip_to_binary(other) do
    # Log error for invalid IP format - this is a programming error
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :config, :error],
      %{count: 1},
      %{issue: "ip_to_binary called with invalid format", value: inspect(other)}
    )

    <<0, 0, 0, 0>>
  end

  # Convert IP tuple to 32-bit integer for DHCPv4 message fields
  defp ip_tuple_to_integer({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    <<integer::32>> = <<a, b, c, d>>
    integer
  end

  defp ip_tuple_to_integer(integer) when is_integer(integer), do: integer
  defp ip_tuple_to_integer(_), do: 0

  # Note: build_client_info moved to OptionParser.build_client_info/2 for single-pass efficiency
  # Legacy option extraction functions removed to avoid duplication

  # Get ACL rules from configuration
  defp get_acl_rules do
    # Load ACL rules from configuration file
    config_path =
      Application.get_env(:yellow_dog_dhcpv4, :acl_config_path, "config/dhcp_acls.toml")

    ACL.load_with_fallback(config_path)
  end

  # Apply custom options to base options list (FR4)
  defp apply_custom_options(base_options, option_set_name, context) do
    # Load custom options from configuration
    config_path =
      Application.get_env(:yellow_dog_dhcpv4, :options_config_path, "config/dhcp_options.toml")

    option_sets = CustomOptions.load_with_fallback(config_path)

    case CustomOptions.get_option_set(option_sets, option_set_name) do
      {:ok, option_set} ->
        # Apply template substitution
        processed_set = CustomOptions.apply_templates(option_set, context)

        # Encode custom options to DHCP format
        custom_options = CustomOptions.encode_options(processed_set.options)

        # Convert custom options to DHCPv4.Message.Option format
        encoded_custom =
          Enum.map(custom_options, fn opt ->
            %DHCPv4.Message.Option{
              type: opt.type,
              length: byte_size(opt.value),
              value: opt.value
            }
          end)

        # Merge custom options with base options (custom options override base)
        merge_options(base_options, encoded_custom)

      {:error, :not_found} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :custom_options, :not_found],
          %{count: 1},
          %{option_set: option_set_name}
        )

        base_options
    end
  end

  # Merge options, with later options (custom) overriding earlier (base)
  defp merge_options(base_options, custom_options) do
    # Build a map of custom option types for fast lookup
    custom_types = MapSet.new(Enum.map(custom_options, & &1.type))

    # Filter out base options that are overridden by custom
    filtered_base =
      Enum.reject(base_options, fn opt -> MapSet.member?(custom_types, opt.type) end)

    # Combine filtered base with custom options
    filtered_base ++ custom_options
  end
end
