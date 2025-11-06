defmodule YellowDog.Dhcpv6.Handler do
  @moduledoc """
  DHCPv6 message handler implementing the Abyss.Handler behaviour.

  Processes DHCPv6 messages including SOLICIT, ADVERTISE, REQUEST,
  REPLY, and other DHCPv6 protocol messages. Handles client identification
  via DUID (DHCP Unique Identifier) and supports IPv6 multicast.
  """

  require Logger

  alias YellowDog.Dhcpv6.LeaseManager

  # DHCPv6 message type constants
  @msg_type_solicit 1
  @msg_type_advertise 2
  @msg_type_request 3
  # @msg_type_confirm 4
  @msg_type_renew 5
  @msg_type_rebind 6
  @msg_type_reply 7
  @msg_type_release 8
  @msg_type_decline 9
  # @msg_type_reconfigure 10
  @msg_type_information_request 11
  @msg_type_relay_forw 12
  @msg_type_relay_repl 13

  # DHCPv6 option codes
  @option_client_id 1
  @option_server_id 2
  @option_ia_na 3
  @option_ia_ta 4
  @option_ia_addr 5
  # @option_oro 6
  @option_preference 7
  # @option_elapsed_time 8
  # @option_status_code 13
  # @option_rapid_commit 14
  @option_dns_servers 23
  @option_domain_list 24
  @option_ia_pd 25
  @option_ia_prefix 26

  @doc """
  Handles incoming DHCPv6 data from clients.
  """
  def handle_data({client_ip, client_port, data}, state) do
    start_time = System.monotonic_time(:microsecond)

    try do
      case DHCPv6.Message.from_iodata(data) do
        {:ok, message} ->
          Logger.debug(
            "Received DHCPv6 message type #{message.msg_type} from #{format_ip(client_ip)}:#{client_port}"
          )

          # Emit telemetry
          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :message_received],
            %{duration: System.monotonic_time(:microsecond) - start_time},
            %{client_ip: client_ip, client_port: client_port, msg_type: message.msg_type}
          )

          handle_dhcpv6_message(message, client_ip, client_port, state, start_time)

        {:error, reason} ->
          Logger.warning(
            "Failed to parse DHCPv6 message from #{format_ip(client_ip)}:#{client_port}: #{inspect(reason)}"
          )

          {:continue, state}
      end
    rescue
      error ->
        Logger.error(
          "Error handling DHCPv6 message from #{format_ip(client_ip)}:#{client_port}: #{inspect(error)}"
        )

        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message_error],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: client_ip, client_port: client_port, error: Exception.message(error)}
        )

        {:continue, state}
    end
  end

  @doc """
  Handles handler errors (implements Abyss.Handler callback).
  """
  def handle_error(error, state) do
    Logger.error("DHCPv6 handler error: #{inspect(error)}")
    {:continue, state}
  end

  @doc """
  Handles handler timeouts (implements Abyss.Handler callback).
  """
  def handle_timeout(state) do
    Logger.debug("DHCPv6 handler timeout")
    {:continue, state}
  end

  # Private functions for handling specific DHCPv6 message types

  defp handle_dhcpv6_message(message, client_ip, client_port, state, start_time) do
    case message.msg_type do
      @msg_type_solicit ->
        handle_solicit(message, client_ip, client_port, state, start_time)

      @msg_type_request ->
        handle_request(message, client_ip, client_port, state, start_time)

      @msg_type_renew ->
        handle_renew(message, client_ip, client_port, state, start_time)

      @msg_type_rebind ->
        handle_rebind(message, client_ip, client_port, state, start_time)

      @msg_type_release ->
        handle_release(message, client_ip, client_port, state, start_time)

      @msg_type_decline ->
        handle_decline(message, client_ip, client_port, state, start_time)

      @msg_type_information_request ->
        handle_inform(message, client_ip, client_port, state, start_time)

      @msg_type_relay_forw ->
        handle_relay_forward(message, client_ip, client_port, state)

      @msg_type_relay_repl ->
        handle_relay_reply(message, client_ip, client_port, state)

      _ ->
        Logger.warning(
          "Unknown DHCPv6 message type: #{message.msg_type} from #{format_ip(client_ip)}:#{client_port}"
        )

        {:continue, state}
    end
  end

  defp handle_solicit(message, client_ip, client_port, state, start_time) do
    Logger.info(
      "DHCPv6 SOLICIT from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})"
    )

    client_duid = get_client_duid(message)
    ia_na = get_ia_na(message)
    ia_ta = get_ia_ta(message)
    ia_pd = get_ia_pd(message)

    # Check if any IA type is present
    case {client_duid, ia_na, ia_ta, ia_pd} do
      {nil, _, _, _} ->
        Logger.warning("SOLICIT missing client DUID")
        {:continue, state}

      {_, nil, nil, nil} ->
        Logger.warning("SOLICIT missing all IA options (IA_NA, IA_TA, IA_PD)")
        {:continue, state}

      {duid, _, _, _} ->
        # Process each IA type
        leases = []

        # Handle IA_NA if present
        leases =
          if ia_na do
            case LeaseManager.allocate_lease(duid, ia_na.iaid) do
              {:ok, lease} ->
                [lease | leases]

              {:error, reason} ->
                Logger.error("Failed to allocate IA_NA lease: #{inspect(reason)}")
                leases
            end
          else
            leases
          end

        # Handle IA_TA if present
        leases =
          if ia_ta do
            case allocate_temporary_address(duid, ia_ta.iaid) do
              {:ok, ta_lease} ->
                [ta_lease | leases]

              {:error, reason} ->
                Logger.error("Failed to allocate IA_TA lease: #{inspect(reason)}")
                leases
            end
          else
            leases
          end

        # Handle IA_PD if present
        leases =
          if ia_pd do
            {:ok, pd_lease} = allocate_prefix_delegation(duid, ia_pd.iaid)
            [pd_lease | leases]
          else
            leases
          end

        if length(leases) > 0 do
          advertise = create_advertise_multi(message, leases)
          send_dhcpv6_response(advertise, client_ip, client_port, state)

          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :solicit_handled],
            %{duration: System.monotonic_time(:microsecond) - start_time},
            %{client_ip: client_ip, duid: format_duid(duid), ia_count: length(leases)}
          )
        end

        {:continue, state}
    end
  end

  defp handle_request(message, client_ip, client_port, state, start_time) do
    Logger.info(
      "DHCPv6 REQUEST from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})"
    )

    client_duid = get_client_duid(message)
    ia_na = get_ia_na(message)

    case {client_duid, ia_na} do
      {nil, _} ->
        Logger.warning("REQUEST missing client DUID")
        {:continue, state}

      {_, nil} ->
        Logger.warning("REQUEST missing IA_NA option")
        {:continue, state}

      {duid, %{iaid: iaid}} ->
        # Allocate or renew lease
        case LeaseManager.allocate_lease(duid, iaid) do
          {:ok, lease} ->
            reply = create_reply(message, lease)
            send_dhcpv6_response(reply, client_ip, client_port, state)

            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :request_handled],
              %{duration: System.monotonic_time(:microsecond) - start_time},
              %{client_ip: client_ip, duid: format_duid(duid)}
            )

          {:error, reason} ->
            Logger.error("Failed to allocate lease for REQUEST: #{inspect(reason)}")
        end

        {:continue, state}
    end
  end

  defp handle_renew(message, client_ip, client_port, state, start_time) do
    Logger.info(
      "DHCPv6 RENEW from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})"
    )

    client_duid = get_client_duid(message)
    ia_na = get_ia_na(message)

    case {client_duid, ia_na} do
      {duid, %{iaid: iaid}} when duid != nil ->
        # Renew existing lease
        case LeaseManager.allocate_lease(duid, iaid) do
          {:ok, lease} ->
            reply = create_reply(message, lease)
            send_dhcpv6_response(reply, client_ip, client_port, state)

            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :renew_handled],
              %{duration: System.monotonic_time(:microsecond) - start_time},
              %{client_ip: client_ip, duid: format_duid(duid)}
            )

          {:error, reason} ->
            Logger.error("Failed to renew lease: #{inspect(reason)}")
        end

        {:continue, state}

      _ ->
        Logger.warning("RENEW missing required options")
        {:continue, state}
    end
  end

  defp handle_rebind(message, client_ip, client_port, state, start_time) do
    Logger.info(
      "DHCPv6 REBIND from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})"
    )

    # Rebind is similar to renew
    handle_renew(message, client_ip, client_port, state, start_time)
  end

  defp handle_release(message, client_ip, client_port, state, start_time) do
    Logger.info(
      "DHCPv6 RELEASE from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})"
    )

    client_duid = get_client_duid(message)
    ia_na = get_ia_na(message)

    case {client_duid, ia_na} do
      {duid, %{iaid: iaid}} when duid != nil ->
        LeaseManager.release_lease(duid, iaid)

        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :release_handled],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: client_ip, duid: format_duid(duid)}
        )

      _ ->
        Logger.warning("RELEASE missing required options")
    end

    {:continue, state}
  end

  defp handle_decline(message, client_ip, client_port, state, start_time) do
    Logger.info(
      "DHCPv6 DECLINE from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})"
    )

    client_duid = get_client_duid(message)
    ia_na = get_ia_na(message)

    case {client_duid, ia_na} do
      {duid, %{ia_addr: ia_addr}} when duid != nil and ia_addr != nil ->
        LeaseManager.decline_ip(ia_addr, duid)

        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :decline_handled],
          %{duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: client_ip, duid: format_duid(duid), declined_ip: ia_addr}
        )

      _ ->
        Logger.warning("DECLINE missing required options")
    end

    {:continue, state}
  end

  defp handle_inform(message, client_ip, client_port, state, start_time) do
    Logger.info(
      "DHCPv6 INFORM from #{format_client_duid(message)} (#{format_ip(client_ip)}:#{client_port})"
    )

    # INFORMATION-REQUEST - provide configuration without address allocation
    reply = create_information_reply(message)
    send_dhcpv6_response(reply, client_ip, client_port, state)

    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :inform_handled],
      %{duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip}
    )

    {:continue, state}
  end

  defp handle_relay_forward(_message, client_ip, client_port, state) do
    Logger.info(
      "DHCPv6 RELAY-FORWARD from #{format_ip(client_ip)}:#{client_port} (not implemented)"
    )

    {:continue, state}
  end

  defp handle_relay_reply(_message, client_ip, client_port, state) do
    Logger.info(
      "DHCPv6 RELAY-REPLY from #{format_ip(client_ip)}:#{client_port} (not implemented)"
    )

    {:continue, state}
  end

  # Message creation functions

  defp create_reply(request, lease) do
    pool = get_pool_for_lease(lease)

    %DHCPv6.Message{
      msg_type: @msg_type_reply,
      transaction_id: request.transaction_id,
      options:
        [
          # Server DUID
          %DHCPv6.Message.Option{option_code: @option_server_id, option_data: get_server_duid()},
          # Client DUID (echo back)
          %DHCPv6.Message.Option{
            option_code: @option_client_id,
            option_data: get_client_duid(request)
          },
          # IA_NA with IA_ADDR
          create_ia_na_option(lease),
          # DNS servers
          create_dns_servers_option(pool.dns_servers)
        ]
        |> add_domain_list_option(pool.domain_name)
    }
  end

  defp create_information_reply(request) do
    pool = get_default_pool()

    %DHCPv6.Message{
      msg_type: @msg_type_reply,
      transaction_id: request.transaction_id,
      options:
        [
          # Server DUID
          %DHCPv6.Message.Option{option_code: @option_server_id, option_data: get_server_duid()},
          # Client DUID (echo back)
          %DHCPv6.Message.Option{
            option_code: @option_client_id,
            option_data: get_client_duid(request)
          },
          # DNS servers
          create_dns_servers_option(pool.dns_servers)
        ]
        |> add_domain_list_option(pool.domain_name)
    }
  end

  # Helper functions for creating options

  defp create_ia_na_option(lease) do
    # IA_ADDR option (option 5) - IPv6 address + lifetimes
    ia_addr_data =
      ipv6_to_binary(lease.ip) <>
        <<lease.preferred_lifetime::32, lease.valid_lifetime::32>>

    ia_addr_option = %DHCPv6.Message.Option{
      option_code: @option_ia_addr,
      option_data: ia_addr_data
    }

    # IA_NA option (option 3) - contains IA_ADDR
    # IAID + T1 + T2 (0 = server decides)
    ia_na_data =
      <<lease.iaid::32, 0::32, 0::32>> <>
        DHCP.Parameter.to_iodata(ia_addr_option)

    %DHCPv6.Message.Option{
      option_code: @option_ia_na,
      option_data: ia_na_data
    }
  end

  defp create_dns_servers_option(dns_servers) do
    dns_data = Enum.map_join(dns_servers, &ipv6_to_binary/1)

    %DHCPv6.Message.Option{
      option_code: @option_dns_servers,
      option_data: dns_data
    }
  end

  defp add_domain_list_option(options, domain) when domain in [nil, ""], do: options

  defp add_domain_list_option(options, domain) do
    # Encode domain name in DNS format (length-prefixed labels)
    domain_data = encode_domain_name(domain)

    domain_option = %DHCPv6.Message.Option{
      option_code: @option_domain_list,
      option_data: domain_data
    }

    options ++ [domain_option]
  end

  defp encode_domain_name(domain) do
    domain
    |> String.split(".")
    |> Enum.map_join(fn label ->
      <<byte_size(label)::8, label::binary>>
    end)
    # Terminating zero
    |> Kernel.<>(<<0>>)
  end

  # Helper functions for extracting information from messages

  defp get_client_duid(message) do
    case Enum.find(message.options, fn opt -> opt.option_code == @option_client_id end) do
      nil -> nil
      option -> option.option_data
    end
  end

  defp get_ia_na(message) do
    case Enum.find(message.options, fn opt -> opt.option_code == @option_ia_na end) do
      nil ->
        nil

      option ->
        # Parse IA_NA: IAID (4 bytes) + T1 (4 bytes) + T2 (4 bytes) + options
        case option.option_data do
          <<iaid::32, _t1::32, _t2::32, rest::binary>> ->
            # Try to extract IA_ADDR if present
            ia_addr = extract_ia_addr(rest)
            %{iaid: iaid, ia_addr: ia_addr, type: :ia_na}

          _ ->
            nil
        end
    end
  end

  defp get_ia_ta(message) do
    case Enum.find(message.options, fn opt -> opt.option_code == @option_ia_ta end) do
      nil ->
        nil

      option ->
        # Parse IA_TA: IAID (4 bytes) + options (no T1/T2)
        case option.option_data do
          <<iaid::32, rest::binary>> ->
            ia_addr = extract_ia_addr(rest)
            %{iaid: iaid, ia_addr: ia_addr, type: :ia_ta}

          _ ->
            nil
        end
    end
  end

  defp get_ia_pd(message) do
    case Enum.find(message.options, fn opt -> opt.option_code == @option_ia_pd end) do
      nil ->
        nil

      option ->
        # Parse IA_PD: IAID (4 bytes) + T1 (4 bytes) + T2 (4 bytes) + options
        case option.option_data do
          <<iaid::32, _t1::32, _t2::32, rest::binary>> ->
            ia_prefix = extract_ia_prefix(rest)
            %{iaid: iaid, ia_prefix: ia_prefix, type: :ia_pd}

          _ ->
            nil
        end
    end
  end

  defp extract_ia_addr(<<@option_ia_addr::16, len::16, data::binary-size(len), _rest::binary>>) do
    case data do
      <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, _lifetimes::binary>> ->
        {a, b, c, d, e, f, g, h}

      _ ->
        nil
    end
  end

  defp extract_ia_addr(_), do: nil

  defp extract_ia_prefix(
         <<@option_ia_prefix::16, len::16, data::binary-size(len), _rest::binary>>
       ) do
    case data do
      <<_preferred::32, _valid::32, prefix_len::8, a::16, b::16, c::16, d::16, e::16, f::16,
        g::16, h::16>> ->
        {{a, b, c, d, e, f, g, h}, prefix_len}

      _ ->
        nil
    end
  end

  defp extract_ia_prefix(_), do: nil

  # Allocation helper functions

  defp allocate_temporary_address(duid, iaid) do
    # Temporary addresses use a separate pool with shorter lifetimes
    # For now, delegate to LeaseManager with IA_TA type marker
    case LeaseManager.allocate_lease(duid, iaid, nil, "default-ta") do
      {:ok, lease} ->
        # Mark as temporary address with shorter lifetime
        ta_lease = %{
          lease
          | ia_type: :ia_ta,
            preferred_lifetime: 600,
            # 10 minutes
            valid_lifetime: 1200
            # 20 minutes
        }

        {:ok, ta_lease}

      error ->
        error
    end
  end

  defp allocate_prefix_delegation(duid, iaid) do
    # For now, return a placeholder
    # Full implementation would use PrefixPool module
    Logger.debug("IA_PD allocation requested for DUID #{format_duid(duid)} IAID #{iaid}")

    # TODO: Integrate with PrefixPool module
    # Example placeholder prefix: 2001:db8:1000::/56
    {:ok,
     %{
       duid: duid,
       iaid: iaid,
       ia_type: :ia_pd,
       delegated_prefix: {{0x2001, 0x0DB8, 0x1000, 0, 0, 0, 0, 0}, 56},
       preferred_lifetime: 3600,
       valid_lifetime: 7200,
       pool_name: "default-pd"
     }}
  end

  # Message creation functions with multi-IA support

  defp create_advertise_multi(solicit, leases) do
    pool = get_default_pool()

    options = [
      # Server DUID
      %DHCPv6.Message.Option{option_code: @option_server_id, option_data: get_server_duid()},
      # Client DUID (echo back)
      %DHCPv6.Message.Option{
        option_code: @option_client_id,
        option_data: get_client_duid(solicit)
      },
      # Preference
      %DHCPv6.Message.Option{option_code: @option_preference, option_data: <<255>>}
    ]

    # Add IA options for each lease
    ia_options =
      Enum.flat_map(leases, fn lease ->
        case lease.ia_type do
          :ia_na -> [create_ia_na_option(lease)]
          :ia_ta -> [create_ia_ta_option(lease)]
          :ia_pd -> [create_ia_pd_option(lease)]
          _ -> []
        end
      end)

    # Add configuration options (DNS, etc.)
    config_options =
      [
        create_dns_servers_option(pool.dns_servers)
      ] ++ add_domain_list_option([], pool.domain_name)

    %DHCPv6.Message{
      msg_type: @msg_type_advertise,
      transaction_id: solicit.transaction_id,
      options: options ++ ia_options ++ config_options
    }
  end

  defp create_ia_ta_option(lease) do
    # IA_ADDR option (option 5) - IPv6 address + lifetimes
    ia_addr_data =
      ipv6_to_binary(lease.ip) <>
        <<lease.preferred_lifetime::32, lease.valid_lifetime::32>>

    ia_addr_option = %DHCPv6.Message.Option{
      option_code: @option_ia_addr,
      option_data: ia_addr_data
    }

    # IA_TA option (option 4) - contains IA_ADDR (no T1/T2)
    ia_ta_data =
      <<lease.iaid::32>> <>
        DHCP.Parameter.to_iodata(ia_addr_option)

    %DHCPv6.Message.Option{
      option_code: @option_ia_ta,
      option_data: ia_ta_data
    }
  end

  defp create_ia_pd_option(lease) do
    {prefix_addr, prefix_len} = lease.delegated_prefix

    # IA_PREFIX option (option 26)
    ia_prefix_data =
      <<lease.preferred_lifetime::32, lease.valid_lifetime::32, prefix_len::8>> <>
        ipv6_to_binary(prefix_addr)

    ia_prefix_option = %DHCPv6.Message.Option{
      option_code: @option_ia_prefix,
      option_data: ia_prefix_data
    }

    # IA_PD option (option 25)
    ia_pd_data =
      <<lease.iaid::32, 0::32, 0::32>> <>
        DHCP.Parameter.to_iodata(ia_prefix_option)

    %DHCPv6.Message.Option{
      option_code: @option_ia_pd,
      option_data: ia_pd_data
    }
  end

  defp get_server_duid do
    # Generate a simple DUID-LL (Link-Layer) based on server
    # DUID Type 3 (DUID-LL): type (2 bytes) + hardware type (2 bytes) + link-layer address
    # Using a static server identifier for now
    <<0, 3, 0, 1, 0x00, 0x00, 0x5E, 0x00, 0x53, 0xFF>>
  end

  defp get_pool_for_lease(_lease) do
    # For now, use default pool
    # In production, look up pool by lease.pool_name
    get_default_pool()
  end

  defp get_default_pool do
    %{
      name: "default",
      range_start: {0xFD00, 0, 0, 0, 0, 0, 0, 0x100},
      range_end: {0xFD00, 0, 0, 0, 0, 0, 0, 0x200},
      prefix_length: 64,
      dns_servers: [{0xFD00, 0, 0, 0, 0, 0, 0, 1}],
      domain_name: "local",
      preferred_lifetime: 3600,
      valid_lifetime: 7200
    }
  end

  defp send_dhcpv6_response(response, client_ip, client_port, state) do
    data = DHCP.Parameter.to_iodata(response)

    case :gen_udp.send(state.socket, client_ip, client_port, data) do
      :ok ->
        Logger.debug(
          "Sent DHCPv6 response type #{response.msg_type} to #{format_ip(client_ip)}:#{client_port}"
        )

      {:error, reason} ->
        Logger.error("Failed to send DHCPv6 response: #{inspect(reason)}")
    end
  end

  # Utility functions

  defp ipv6_to_binary({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  defp format_client_duid(message) do
    case get_client_duid(message) do
      nil -> "unknown_duid"
      duid -> format_duid(duid)
    end
  end

  defp format_duid(duid) when is_binary(duid) do
    "DUID:#{:erlang.phash2(duid) |> Integer.to_string(16) |> String.upcase()}"
  end

  defp format_duid(_), do: "UNKNOWN"

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
