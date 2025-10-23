defmodule DHCPv6.Server do
  import Bitwise

  @moduledoc """
  DHCPv6 Server Core - Pure Elixir DHCPv6 protocol implementation.

  This module provides the core DHCPv6 server logic without networking concerns.
  It handles lease management, IPv6 address allocation, and DHCPv6 message processing.
  """

  alias DHCPv6.Message
  alias DHCPv6.Message.Option
  alias DHCPv6.Config

  @type lease :: %{
          ip: :inet.ip6_address(),
          duid: binary(),
          iaid: integer(),
          expires_at: integer(),
          preferred_lifetime: integer(),
          valid_lifetime: integer(),
          options: [Option.t()]
        }

  @type state :: %{
          config: Config.t(),
          leases: %{binary() => %{integer() => lease()}},
          ip_pool: MapSet.t(:inet.ip6_address()),
          used_ips: MapSet.t(:inet.ip6_address())
        }

  @doc """
  Initialize DHCPv6 server with configuration.
  """
  @spec init(Config.t()) :: state()
  def init(config) do
    ip_pool = generate_ip_pool(config.range_start, config.range_end)

    %{
      config: config,
      leases: %{},
      ip_pool: ip_pool,
      used_ips: MapSet.new()
    }
  end

  @doc """
  Process incoming DHCPv6 message and return response messages.
  """
  @spec process_message(state(), Message.t(), :inet.ip6_address(), integer()) ::
          {state(), [Message.t()]}
  def process_message(state, message, _client_ip, _port) do
    case message.msg_type do
      # SOLICIT
      1 -> handle_solicit(state, message)
      # REQUEST
      3 -> handle_request(state, message)
      # CONFIRM
      4 -> handle_confirm(state, message)
      # RENEW
      5 -> handle_renew(state, message)
      # REBIND
      6 -> handle_rebind(state, message)
      # RELEASE
      8 -> handle_release(state, message)
      # INFORMATION-REQUEST
      10 -> handle_information_request(state, message)
      # Unknown/unsupported
      _ -> {state, []}
    end
  end

  @doc """
  Get current leases for monitoring/debugging.
  """
  @spec get_leases(state()) :: [lease()]
  def get_leases(state) do
    state.leases
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
    |> Enum.filter(&(&1.expires_at > System.system_time(:second)))
  end

  @doc """
  Manually expire leases (for testing/cleanup).
  """
  @spec expire_leases(state()) :: state()
  def expire_leases(state) do
    now = System.system_time(:second)

    {expired_leases, active_leases} =
      state.leases
      |> Enum.flat_map(fn {duid, ia_leases} ->
        Enum.map(ia_leases, fn {iaid, lease} -> {{duid, iaid}, lease} end)
      end)
      |> Enum.split_with(fn {_key, lease} -> lease.expires_at <= now end)

    expired_ips =
      expired_leases
      |> Enum.map(fn {_key, lease} -> lease.ip end)

    new_leases =
      active_leases
      |> Enum.group_by(fn {{duid, _iaid}, _lease} -> duid end, fn {{_duid, iaid}, lease} ->
        {iaid, lease}
      end)
      |> Enum.map(fn {duid, leases} -> {duid, Map.new(leases)} end)
      |> Map.new()

    %{
      state
      | leases: new_leases,
        used_ips: MapSet.difference(state.used_ips, MapSet.new(expired_ips))
    }
  end

  ## Message Handlers

  defp handle_solicit(state, message) do
    duid = extract_duid(message)
    ia_na_options = find_ia_na_options(message)

    if state.config.rapid_commit && has_rapid_commit(message) do
      # Rapid commit - immediate assignment
      case assign_addresses(state, duid, ia_na_options) do
        {:ok, addresses, new_state} ->
          responses = build_reply(new_state, message, addresses, true)
          {new_state, responses}

        {:error, :no_available_ips} ->
          {state, [build_reply_no_addrs(message)]}
      end
    else
      # Normal solicit - advertise
      case find_available_addresses(state, ia_na_options) do
        {:ok, addresses} ->
          {state, [build_advertise(state, message, addresses)]}

        {:error, :no_available_ips} ->
          {state, [build_advertise_no_addrs(message)]}
      end
    end
  end

  defp handle_request(state, message) do
    duid = extract_duid(message)
    ia_na_options = find_ia_na_options(message)

    case validate_addresses(state, duid, ia_na_options) do
      {:ok, addresses, new_state} ->
        responses = build_reply(new_state, message, addresses, false)
        {new_state, responses}

      {:error, reason} ->
        {state, [build_reply_failure(message, reason)]}
    end
  end

  defp handle_confirm(state, message) do
    duid = extract_duid(message)
    ia_na_options = find_ia_na_options(message)

    case validate_existing_addresses(state, duid, ia_na_options) do
      {:ok, addresses} ->
        {state, [build_reply(state, message, addresses, false)]}

      {:error, reason} ->
        {state, [build_reply_failure(message, reason)]}
    end
  end

  defp handle_renew(state, message) do
    handle_renew_or_rebind(state, message)
  end

  defp handle_rebind(state, message) do
    handle_renew_or_rebind(state, message)
  end

  defp handle_renew_or_rebind(state, message) do
    duid = extract_duid(message)
    ia_na_options = find_ia_na_options(message)

    case renew_addresses(state, duid, ia_na_options) do
      {:ok, addresses, new_state} ->
        responses = build_reply(new_state, message, addresses, false)
        {new_state, responses}

      {:error, reason} ->
        {state, [build_reply_failure(message, reason)]}
    end
  end

  defp handle_release(state, message) do
    duid = extract_duid(message)
    ia_na_options = find_ia_na_options(message)

    new_state = release_addresses(state, duid, ia_na_options)
    {new_state, [build_reply_release(message)]}
  end

  defp handle_information_request(state, message) do
    {state, [build_information_reply(state, message)]}
  end

  ## Address Management

  defp assign_addresses(state, duid, ia_na_options) do
    ia_na_options
    |> Enum.map(fn {iaid, t1, t2, requested_addrs} ->
      available_ips = MapSet.difference(state.ip_pool, state.used_ips)

      if MapSet.size(available_ips) > 0 do
        ip = choose_ip(available_ips, requested_addrs)
        lease = create_lease(state.config, duid, iaid, ip, t1, t2)

        {iaid, {ip, lease}}
      else
        {:error, :no_available_ips}
      end
    end)
    |> Enum.reduce_while({:ok, [], state}, fn
      {:error, reason}, _acc ->
        {:halt, {:error, reason}}

      {iaid, {ip, lease}}, {:ok, addresses, acc_state} ->
        new_state = %{
          acc_state
          | leases: put_in(acc_state.leases, [duid, iaid], lease),
            used_ips: MapSet.put(acc_state.used_ips, ip)
        }

        {:cont, {:ok, [{iaid, ip, lease} | addresses], new_state}}
    end)
    |> case do
      {:ok, addresses, new_state} -> {:ok, Enum.reverse(addresses), new_state}
      error -> error
    end
  end

  defp find_available_addresses(state, ia_na_options) do
    ia_na_options
    |> Enum.map(fn {iaid, _t1, _t2, requested_addrs} ->
      available_ips = MapSet.difference(state.ip_pool, state.used_ips)

      if MapSet.size(available_ips) > 0 do
        ip = choose_ip(available_ips, requested_addrs)
        {iaid, ip}
      else
        {:error, :no_available_ips}
      end
    end)
    |> Enum.reduce_while({:ok, []}, fn
      {:error, reason}, _acc -> {:halt, {:error, reason}}
      {iaid, ip}, {:ok, addresses} -> {:cont, {:ok, [{iaid, ip} | addresses]}}
    end)
    |> case do
      {:ok, addresses} -> {:ok, Enum.reverse(addresses)}
      error -> error
    end
  end

  defp validate_addresses(state, duid, ia_na_options) do
    ia_na_options
    |> Enum.map(fn {iaid, t1, t2, requested_addrs} ->
      case Map.get(state.leases, duid) && Map.get(state.leases[duid], iaid) do
        nil ->
          # New assignment
          assign_new_address(state, duid, iaid, t1, t2, requested_addrs)

        lease ->
          # Existing lease renewal
          if Enum.empty?(requested_addrs) or MapSet.member?(requested_addrs, lease.ip) do
            {iaid, lease.ip, lease}
          else
            assign_new_address(state, duid, iaid, t1, t2, requested_addrs)
          end
      end
    end)
    |> Enum.reduce_while({:ok, [], state}, fn
      {:error, reason}, _acc ->
        {:halt, {:error, reason}}

      {iaid, ip, lease}, {:ok, addresses, acc_state} ->
        new_state = update_lease(acc_state, duid, iaid, lease)
        {:cont, {:ok, [{iaid, ip, lease} | addresses], new_state}}
    end)
    |> case do
      {:ok, addresses, new_state} -> {:ok, Enum.reverse(addresses), new_state}
      error -> error
    end
  end

  defp assign_new_address(state, duid, iaid, t1, t2, requested_addrs) do
    available_ips = MapSet.difference(state.ip_pool, state.used_ips)

    if MapSet.size(available_ips) > 0 do
      ip = choose_ip(available_ips, requested_addrs)
      lease = create_lease(state.config, duid, iaid, ip, t1, t2)
      {iaid, ip, lease}
    else
      {:error, :no_available_ips}
    end
  end

  defp renew_addresses(state, duid, ia_na_options) do
    ia_na_options
    |> Enum.map(fn {iaid, t1, t2, requested_addrs} ->
      case Map.get(state.leases, duid) && Map.get(state.leases[duid], iaid) do
        nil ->
          assign_new_address(state, duid, iaid, t1, t2, requested_addrs)

        lease ->
          renewed_lease = %{
            lease
            | expires_at: System.system_time(:second) + state.config.lease_time,
              preferred_lifetime: t1,
              valid_lifetime: t2
          }

          {iaid, lease.ip, renewed_lease}
      end
    end)
    |> Enum.reduce_while({:ok, [], state}, fn
      {:error, reason}, _acc ->
        {:halt, {:error, reason}}

      {iaid, ip, lease}, {:ok, addresses, acc_state} ->
        new_state = update_lease(acc_state, duid, iaid, lease)
        {:cont, {:ok, [{iaid, ip, lease} | addresses], new_state}}
    end)
    |> case do
      {:ok, addresses, new_state} -> {:ok, Enum.reverse(addresses), new_state}
      error -> error
    end
  end

  defp release_addresses(state, duid, ia_na_options) do
    ia_na_options
    |> Enum.reduce(state, fn {iaid, _t1, _t2, _requested_addrs}, acc_state ->
      case Map.get(acc_state.leases, duid) && Map.get(acc_state.leases[duid], iaid) do
        nil ->
          acc_state

        lease ->
          new_leases =
            case Map.get(acc_state.leases, duid) do
              nil -> acc_state.leases
              duid_leases -> Map.put(acc_state.leases, duid, Map.delete(duid_leases, iaid))
            end

          %{
            acc_state
            | leases: new_leases,
              used_ips: MapSet.delete(acc_state.used_ips, lease.ip)
          }
      end
    end)
  end

  defp validate_existing_addresses(state, duid, ia_na_options) do
    ia_na_options
    |> Enum.map(fn {iaid, _t1, _t2, requested_addrs} ->
      case Map.get(state.leases, duid) && Map.get(state.leases[duid], iaid) do
        nil ->
          {:error, :no_binding}

        lease ->
          if MapSet.size(requested_addrs) == 0 || MapSet.member?(requested_addrs, lease.ip) do
            {:ok, [{iaid, lease.ip, lease}]}
          else
            {:error, :not_on_link}
          end
      end
    end)
    |> Enum.reduce_while({:ok, [], state}, fn
      {:error, reason}, _acc ->
        {:halt, {:error, reason}}

      {:ok, addresses}, {:ok, acc_addresses, acc_state} ->
        {:cont, {:ok, addresses ++ acc_addresses, acc_state}}
    end)
  end

  defp create_lease(config, duid, iaid, ip, t1, t2) do
    %{
      ip: ip,
      duid: duid,
      iaid: iaid,
      expires_at: System.system_time(:second) + config.lease_time,
      preferred_lifetime: t1,
      valid_lifetime: t2,
      options: config.options
    }
  end

  defp update_lease(state, duid, iaid, lease) do
    case Map.get(state.leases, duid) do
      nil ->
        %{state | leases: Map.put(state.leases, duid, Map.put(%{}, iaid, lease))}

      duid_leases ->
        %{state | leases: Map.put(state.leases, duid, Map.put(duid_leases, iaid, lease))}
    end
  end

  defp choose_ip(available_ips, requested_addrs) do
    requested_list = MapSet.to_list(requested_addrs)

    Enum.find_value(requested_list, fn requested_ip ->
      if MapSet.member?(available_ips, requested_ip), do: requested_ip, else: nil
    end) || MapSet.to_list(available_ips) |> List.first()
  end

  defp generate_ip_pool(start_ip, end_ip) do
    start_int = ip6_to_int(start_ip)
    end_int = ip6_to_int(end_ip)

    Enum.reduce(start_int..end_int, MapSet.new(), fn ip_int, acc ->
      MapSet.put(acc, int_to_ip6(ip_int))
    end)
  end

  defp ip6_to_int({a, b, c, d, e, f, g, h}) do
    Bitwise.bsl(a, 112) ||| Bitwise.bsl(b, 96) ||| Bitwise.bsl(c, 80) ||| Bitwise.bsl(d, 64) |||
      Bitwise.bsl(e, 48) ||| Bitwise.bsl(f, 32) ||| Bitwise.bsl(g, 16) ||| h
  end

  defp int_to_ip6(int) do
    {
      Bitwise.bsr(int, 112) &&& 0xFFFF,
      Bitwise.bsr(int, 96) &&& 0xFFFF,
      Bitwise.bsr(int, 80) &&& 0xFFFF,
      Bitwise.bsr(int, 64) &&& 0xFFFF,
      Bitwise.bsr(int, 48) &&& 0xFFFF,
      Bitwise.bsr(int, 32) &&& 0xFFFF,
      Bitwise.bsr(int, 16) &&& 0xFFFF,
      int &&& 0xFFFF
    }
  end

  ## Message Building

  defp build_advertise(state, message, addresses) do
    build_reply_message(state, message, addresses, false, false)
  end

  defp build_advertise_no_addrs(message) do
    Message.new()
    # ADVERTISE
    |> Map.put(:msg_type, 2)
    |> Map.put(:transaction_id, message.transaction_id)
    |> add_status_code_option(2, "No addresses available")
  end

  defp build_reply(state, message, addresses, rapid_commit) do
    build_reply_message(state, message, addresses, true, rapid_commit)
  end

  defp build_reply_message(state, message, addresses, include_ia_na, rapid_commit) do
    Message.new()
    # REPLY
    |> Map.put(:msg_type, 7)
    |> Map.put(:transaction_id, message.transaction_id)
    |> maybe_add_rapid_commit(rapid_commit)
    |> add_dns_servers(state.config.dns_servers)
    |> add_ia_na_options(addresses, include_ia_na)
  end

  defp build_reply_no_addrs(message) do
    Message.new()
    # REPLY
    |> Map.put(:msg_type, 7)
    |> Map.put(:transaction_id, message.transaction_id)
    |> add_status_code_option(2, "No addresses available")
  end

  defp build_reply_failure(message, reason) do
    Message.new()
    # REPLY
    |> Map.put(:msg_type, 7)
    |> Map.put(:transaction_id, message.transaction_id)
    |> add_status_code_option(1, Atom.to_string(reason))
  end

  defp build_reply_release(message) do
    Message.new()
    # REPLY
    |> Map.put(:msg_type, 7)
    |> Map.put(:transaction_id, message.transaction_id)
    |> add_status_code_option(0, "Success")
  end

  defp build_information_reply(state, message) do
    Message.new()
    # REPLY
    |> Map.put(:msg_type, 7)
    |> Map.put(:transaction_id, message.transaction_id)
    |> add_dns_servers(state.config.dns_servers)
    |> add_status_code_option(0, "Success")
  end

  defp maybe_add_rapid_commit(message, false), do: message

  defp maybe_add_rapid_commit(message, true) do
    # RAPID_COMMIT
    option = Option.new(14, <<>>)
    %{message | options: [option | message.options]}
  end

  defp add_dns_servers(message, servers) when length(servers) > 0 do
    server_data = Enum.map(servers, &ip6_to_binary/1) |> Enum.join()
    # DNS_SERVERS
    option = Option.new(23, server_data)
    %{message | options: [option | message.options]}
  end

  defp add_dns_servers(message, _), do: message

  defp add_ia_na_options(message, addresses, true) do
    addresses
    |> Enum.reduce(message, fn {iaid, ip, lease}, acc ->
      ia_na_option =
        Option.ia_na(
          iaid,
          lease.preferred_lifetime,
          lease.valid_lifetime,
          [ip]
        )

      %{acc | options: [ia_na_option | acc.options]}
    end)
  end

  defp add_ia_na_options(message, _addresses, false), do: message

  defp add_status_code_option(message, code, message_text) do
    option_data = <<code::16, message_text::binary>>
    # STATUS_CODE
    option = Option.new(13, option_data)
    %{message | options: [option | message.options]}
  end

  ## Helper Functions

  defp extract_duid(message) do
    Enum.find_value(message.options, fn option ->
      if option.option_code == 1, do: option.option_data, else: nil
    end) || <<>>
  end

  defp find_ia_na_options(message) do
    message.options
    # IA_NA
    |> Enum.filter(&(&1.option_code == 3))
    |> Enum.map(fn option ->
      <<iaid::32, t1::32, t2::32, rest::binary>> = option.option_data
      addresses = parse_ia_addresses(rest)
      {iaid, t1, t2, addresses}
    end)
  end

  defp parse_ia_addresses(data) do
    parse_ia_addresses(data, MapSet.new())
  end

  defp parse_ia_addresses("<<>>", acc), do: acc

  defp parse_ia_addresses(
         <<5::16, option_length::16, addr_data::binary-size(option_length), rest::binary>>,
         acc
       ) do
    case parse_ipv6_address(addr_data) do
      {:ok, addr} -> parse_ia_addresses(rest, MapSet.put(acc, addr))
      {:error, _} -> parse_ia_addresses(rest, acc)
    end
  end

  defp parse_ia_addresses(_, acc), do: acc

  defp parse_ipv6_address(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>) do
    {:ok, {a, b, c, d, e, f, g, h}}
  end

  defp parse_ipv6_address(_), do: {:error, "Invalid IPv6 address"}

  defp has_rapid_commit(message) do
    Enum.any?(message.options, &(&1.option_code == 14))
  end

  defp ip6_to_binary({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end
end
