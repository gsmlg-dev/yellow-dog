defmodule YellowDog.Dhcpv6.Handler do
  @moduledoc """
  DHCPv6 message handler implementing the Abyss.Handler behaviour.

  Processes DHCPv6 messages including SOLICIT, ADVERTISE, REQUEST,
  REPLY, and other DHCPv6 protocol messages. Handles client identification
  via DUID (DHCP Unique Identifier) and supports IPv6 multicast.
  """

  use Abyss.Handler

  alias YellowDog.Dhcpv6.{LeaseManager, OptionParser, RateLimiter}

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
  @impl true
  def handle_data({client_ip, client_port, data}, state) do
    start_time = System.monotonic_time(:microsecond)

    # Check rate limit before processing
    case RateLimiter.check_rate(client_ip) do
      :ok ->
        process_message(client_ip, client_port, data, state, start_time)

      {:error, :rate_limited} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :rate_limited],
          %{count: 1},
          %{client_ip: client_ip, client_port: client_port}
        )

        {:continue, state}
    end
  end

  defp process_message(client_ip, client_port, data, state, start_time) do
    try do
      case DHCPv6.Message.from_iodata(data) do
        {:ok, message} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :message, :received],
            %{count: 1, duration: System.monotonic_time(:microsecond) - start_time},
            %{client_ip: client_ip, client_port: client_port, msg_type: message.msg_type}
          )

          handle_dhcpv6_message(message, client_ip, client_port, state, start_time)

        {:error, reason} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :message, :parse_error],
            %{count: 1},
            %{client_ip: client_ip, client_port: client_port, reason: inspect(reason)}
          )

          {:continue, state}
      end
    rescue
      error ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :error],
          %{count: 1, duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: client_ip, client_port: client_port, error: Exception.message(error)}
        )

        {:continue, state}
    end
  end

  @doc """
  Handles handler errors (implements Abyss.Handler callback).
  """
  @impl true
  def handle_error(error, state) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :handler, :error],
      %{count: 1},
      %{reason: inspect(error)}
    )

    {:continue, state}
  end

  @doc """
  Handles handler timeouts (implements Abyss.Handler callback).
  """
  @impl true
  def handle_timeout(state) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :handler, :timeout],
      %{count: 1},
      %{}
    )

    {:continue, state}
  end

  # Private functions for handling specific DHCPv6 message types

  defp handle_dhcpv6_message(message, client_ip, client_port, state, start_time) do
    # Single-pass option extraction for better performance
    # Extracts all commonly needed options in O(n) instead of O(n*m)
    parsed_opts = OptionParser.extract_common(message.options)

    case message.msg_type do
      @msg_type_solicit ->
        handle_solicit(message, parsed_opts, client_ip, client_port, state, start_time)

      @msg_type_request ->
        handle_request(message, parsed_opts, client_ip, client_port, state, start_time)

      @msg_type_renew ->
        handle_renew(message, parsed_opts, client_ip, client_port, state, start_time)

      @msg_type_rebind ->
        handle_rebind(message, parsed_opts, client_ip, client_port, state, start_time)

      @msg_type_release ->
        handle_release(message, parsed_opts, client_ip, client_port, state, start_time)

      @msg_type_decline ->
        handle_decline(message, parsed_opts, client_ip, client_port, state, start_time)

      @msg_type_information_request ->
        handle_inform(message, parsed_opts, client_ip, client_port, state, start_time)

      @msg_type_relay_forw ->
        handle_relay_forward(message, client_ip, client_port, state)

      @msg_type_relay_repl ->
        handle_relay_reply(message, client_ip, client_port, state)

      _ ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :unknown],
          %{count: 1},
          %{client_ip: client_ip, client_port: client_port, msg_type: message.msg_type}
        )

        {:continue, state}
    end
  end

  defp handle_solicit(message, parsed_opts, client_ip, client_port, state, start_time) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease, :requested],
      %{count: 1},
      %{client_ip: client_ip, client_port: client_port, message_type: :solicit}
    )

    # Use pre-parsed options for efficiency
    client_duid = parsed_opts.client_id
    ia_na = parsed_opts.ia_na
    ia_ta = parsed_opts.ia_ta
    ia_pd = parsed_opts.ia_pd

    # Check if any IA type is present
    case {client_duid, ia_na, ia_ta, ia_pd} do
      {nil, _, _, _} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :invalid],
          %{count: 1},
          %{reason: "SOLICIT missing client DUID", client_ip: client_ip}
        )

        {:continue, state}

      {_, nil, nil, nil} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :invalid],
          %{count: 1},
          %{reason: "SOLICIT missing all IA options", client_ip: client_ip}
        )

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
                :telemetry.execute(
                  [:yellow_dog, :dhcpv6, :lease, :allocation_failed],
                  %{count: 1},
                  %{reason: inspect(reason), ia_type: :ia_na, client_duid: duid}
                )

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
                :telemetry.execute(
                  [:yellow_dog, :dhcpv6, :lease, :allocation_failed],
                  %{count: 1},
                  %{reason: inspect(reason), ia_type: :ia_ta, client_duid: duid}
                )

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
          advertise = create_advertise_multi(message, leases, parsed_opts)
          send_dhcpv6_response(advertise, client_ip, client_port, state)

          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :solicit, :completed],
            %{count: 1, duration: System.monotonic_time(:microsecond) - start_time},
            %{client_ip: client_ip, client_duid: duid, ia_count: length(leases)}
          )
        end

        {:continue, state}
    end
  end

  defp handle_request(message, parsed_opts, client_ip, client_port, state, start_time) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease, :requested],
      %{count: 1},
      %{client_ip: client_ip, client_port: client_port, message_type: :request}
    )

    # Use pre-parsed options for efficiency
    client_duid = parsed_opts.client_id
    ia_na = parsed_opts.ia_na

    case {client_duid, ia_na} do
      {nil, _} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :invalid],
          %{count: 1},
          %{reason: "REQUEST missing client DUID", client_ip: client_ip}
        )

        {:continue, state}

      {_, nil} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :invalid],
          %{count: 1},
          %{reason: "REQUEST missing IA_NA option", client_ip: client_ip}
        )

        {:continue, state}

      {duid, %{iaid: iaid}} ->
        # Allocate or renew lease
        case LeaseManager.allocate_lease(duid, iaid) do
          {:ok, lease} ->
            reply = create_reply(message, lease, parsed_opts)
            send_dhcpv6_response(reply, client_ip, client_port, state)

            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :lease, :granted],
              %{count: 1, duration: System.monotonic_time(:microsecond) - start_time},
              %{client_ip: client_ip, client_duid: duid}
            )

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :lease, :allocation_failed],
              %{count: 1},
              %{reason: inspect(reason), client_duid: duid}
            )
        end

        {:continue, state}
    end
  end

  defp handle_renew(message, parsed_opts, client_ip, client_port, state, start_time) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease, :renewed],
      %{count: 1},
      %{client_ip: client_ip, client_port: client_port, message_type: :renew}
    )

    # Use pre-parsed options for efficiency
    client_duid = parsed_opts.client_id
    ia_na = parsed_opts.ia_na

    case {client_duid, ia_na} do
      {duid, %{iaid: iaid}} when duid != nil ->
        # Renew existing lease
        case LeaseManager.allocate_lease(duid, iaid) do
          {:ok, lease} ->
            reply = create_reply(message, lease, parsed_opts)
            send_dhcpv6_response(reply, client_ip, client_port, state)

            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :lease, :granted],
              %{count: 1, duration: System.monotonic_time(:microsecond) - start_time},
              %{client_ip: client_ip, client_duid: duid}
            )

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :lease, :renew_failed],
              %{count: 1},
              %{reason: inspect(reason), client_duid: duid}
            )
        end

        {:continue, state}

      _ ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :invalid],
          %{count: 1},
          %{reason: "RENEW missing required options", client_ip: client_ip}
        )

        {:continue, state}
    end
  end

  defp handle_rebind(message, parsed_opts, client_ip, client_port, state, start_time) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease, :rebind],
      %{count: 1},
      %{client_ip: client_ip, client_port: client_port, message_type: :rebind}
    )

    # Rebind is similar to renew - use pre-parsed options
    client_duid = parsed_opts.client_id
    ia_na = parsed_opts.ia_na

    case {client_duid, ia_na} do
      {duid, %{iaid: iaid}} when duid != nil ->
        case LeaseManager.allocate_lease(duid, iaid) do
          {:ok, lease} ->
            reply = create_reply(message, lease, parsed_opts)
            send_dhcpv6_response(reply, client_ip, client_port, state)

            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :lease, :granted],
              %{count: 1, duration: System.monotonic_time(:microsecond) - start_time},
              %{client_ip: client_ip, client_duid: duid}
            )

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :lease, :rebind_failed],
              %{count: 1},
              %{reason: inspect(reason), client_duid: duid}
            )
        end

        {:continue, state}

      _ ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :invalid],
          %{count: 1},
          %{reason: "REBIND missing required options", client_ip: client_ip}
        )

        {:continue, state}
    end
  end

  defp handle_release(_message, parsed_opts, client_ip, client_port, state, start_time) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease, :released],
      %{count: 1},
      %{client_ip: client_ip, client_port: client_port, message_type: :release}
    )

    # Use pre-parsed options for efficiency
    client_duid = parsed_opts.client_id
    ia_na = parsed_opts.ia_na

    case {client_duid, ia_na} do
      {duid, %{iaid: iaid}} when duid != nil ->
        LeaseManager.release_lease(duid, iaid)

        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease, :release_completed],
          %{count: 1, duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: client_ip, client_duid: duid}
        )

      _ ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :invalid],
          %{count: 1},
          %{reason: "RELEASE missing required options", client_ip: client_ip}
        )
    end

    {:continue, state}
  end

  defp handle_decline(_message, parsed_opts, client_ip, client_port, state, start_time) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease, :declined],
      %{count: 1},
      %{client_ip: client_ip, client_port: client_port, message_type: :decline}
    )

    # Use pre-parsed options for efficiency
    client_duid = parsed_opts.client_id
    ia_na = parsed_opts.ia_na

    case {client_duid, ia_na} do
      {duid, %{ia_addr: ia_addr}} when duid != nil and ia_addr != nil ->
        LeaseManager.decline_ip(ia_addr, duid)

        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease, :decline_completed],
          %{count: 1, duration: System.monotonic_time(:microsecond) - start_time},
          %{client_ip: client_ip, client_duid: duid, declined_ip: ia_addr}
        )

      _ ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :message, :invalid],
          %{count: 1},
          %{reason: "DECLINE missing required options", client_ip: client_ip}
        )
    end

    {:continue, state}
  end

  defp handle_inform(message, parsed_opts, client_ip, client_port, state, start_time) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :inform, :requested],
      %{count: 1},
      %{client_ip: client_ip, client_port: client_port, message_type: :information_request}
    )

    # INFORMATION-REQUEST - provide configuration without address allocation
    reply = create_information_reply(message, parsed_opts)
    send_dhcpv6_response(reply, client_ip, client_port, state)

    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :inform, :completed],
      %{count: 1, duration: System.monotonic_time(:microsecond) - start_time},
      %{client_ip: client_ip}
    )

    {:continue, state}
  end

  defp handle_relay_forward(_message, client_ip, client_port, state) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :relay, :forward],
      %{count: 1},
      %{client_ip: client_ip, client_port: client_port, status: :not_implemented}
    )

    {:continue, state}
  end

  defp handle_relay_reply(_message, client_ip, client_port, state) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :relay, :reply],
      %{count: 1},
      %{client_ip: client_ip, client_port: client_port, status: :not_implemented}
    )

    {:continue, state}
  end

  # Message creation functions

  defp create_reply(request, lease, parsed_opts) do
    pool = get_pool_for_lease(lease)

    # Use pre-parsed client_id for efficiency
    client_id = parsed_opts.client_id

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
            option_data: client_id
          },
          # IA_NA with IA_ADDR
          create_ia_na_option(lease),
          # DNS servers
          create_dns_servers_option(pool.dns_servers)
        ]
        |> add_domain_list_option(pool.domain_name)
    }
  end

  defp create_information_reply(request, parsed_opts) do
    pool = get_default_pool()

    # Use pre-parsed client_id for efficiency
    client_id = parsed_opts.client_id

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
            option_data: client_id
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
    # RFC 1035: Each label is limited to 63 octets
    domain
    |> String.split(".")
    |> Enum.map_join(fn label ->
      # Enforce max label length per DNS specification
      truncated_label =
        if byte_size(label) > 63 do
          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :config, :warning],
            %{count: 1},
            %{issue: "DNS label truncated", original_length: byte_size(label)}
          )

          binary_part(label, 0, 63)
        else
          label
        end

      <<byte_size(truncated_label)::8, truncated_label::binary>>
    end)
    # Terminating zero
    |> Kernel.<>(<<0>>)
  end

  # NOTE: Helper functions get_client_duid, get_ia_na, get_ia_ta, get_ia_pd,
  # extract_ia_addr, and extract_ia_prefix have been moved to OptionParser module
  # for single-pass option extraction. See YellowDog.Dhcpv6.OptionParser.

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
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :prefix, :delegation_requested],
      %{count: 1},
      %{client_duid: duid, iaid: iaid}
    )

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

  defp create_advertise_multi(solicit, leases, parsed_opts) do
    pool = get_default_pool()

    # Use pre-parsed client_id for efficiency
    client_id = parsed_opts.client_id

    options = [
      # Server DUID
      %DHCPv6.Message.Option{option_code: @option_server_id, option_data: get_server_duid()},
      # Client DUID (echo back)
      %DHCPv6.Message.Option{
        option_code: @option_client_id,
        option_data: client_id
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
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :response, :sent],
          %{count: 1},
          %{client_ip: client_ip, client_port: client_port, msg_type: response.msg_type}
        )

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :response, :send_failed],
          %{count: 1},
          %{client_ip: client_ip, client_port: client_port, reason: inspect(reason)}
        )
    end
  end

  # Utility functions

  defp ipv6_to_binary({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end
end
