defmodule DHCPv4.Server do
  import Bitwise

  @moduledoc """
  DHCP Server Core - Pure Elixir DHCP protocol implementation for :abyss integration.

  This module provides the core DHCP server logic without networking concerns.
  It handles lease management, IP allocation, and DHCP message processing.
  """

  alias DHCPv4.Message
  alias DHCPv4.Message.Option

  @type lease :: %{
          ip: :inet.ip4_address(),
          mac: binary(),
          expires_at: integer(),
          client_id: binary() | nil,
          hostname: String.t() | nil,
          options: [Option.t()]
        }

  @type config :: %{
          subnet: :inet.ip4_address(),
          netmask: :inet.ip4_address(),
          range_start: :inet.ip4_address(),
          range_end: :inet.ip4_address(),
          gateway: :inet.ip4_address() | nil,
          dns_servers: [:inet.ip4_address()],
          lease_time: integer(),
          options: [Option.t()]
        }

  @type state :: %{
          config: config(),
          leases: %{binary() => lease()},
          ip_pool: MapSet.t(:inet.ip4_address()),
          used_ips: MapSet.t(:inet.ip4_address())
        }

  @doc """
  Initialize DHCP server with configuration.
  """
  @spec init(config()) :: state()
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
  Process incoming DHCP message and return response messages.
  """
  @spec process_message(state(), Message.t(), :inet.ip4_address(), integer()) ::
          {state(), [Message.t()]}
  def process_message(state, message, _client_ip, _port) do
    case get_message_type(message) do
      # DHCPDISCOVER
      1 -> handle_discover(state, message)
      # DHCPREQUEST
      3 -> handle_request(state, message)
      # DHCPDECLINE
      4 -> handle_decline(state, message)
      # DHCPRELEASE
      7 -> handle_release(state, message)
      # DHCPINFORM
      8 -> handle_inform(state, message)
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
      |> Enum.split_with(fn {_key, lease} -> lease.expires_at <= now end)

    expired_ips =
      expired_leases
      |> Enum.map(fn {_key, lease} -> lease.ip end)

    %{
      state
      | leases: Map.new(active_leases),
        used_ips: MapSet.difference(state.used_ips, MapSet.new(expired_ips))
    }
  end

  ## Message Handlers

  defp handle_discover(state, message) do
    chaddr = extract_client_mac(message)

    case find_or_create_lease(state, chaddr, message) do
      {:ok, lease, new_state} ->
        response = build_offer(new_state, message, lease)
        {new_state, [response]}

      {:error, :no_available_ips} ->
        # No response if no IPs available
        {state, []}
    end
  end

  defp handle_request(state, message) do
    chaddr = extract_client_mac(message)

    case validate_lease(state, chaddr, message) do
      {:ok, lease, new_state} ->
        response = build_ack(new_state, message, lease)
        {new_state, [response]}

      {:error, _reason} ->
        response = build_nak(message, "Requested address not available")
        {state, [response]}
    end
  end

  defp handle_decline(state, message) do
    chaddr = extract_client_mac(message)
    requested_ip = find_requested_ip(message)

    if requested_ip do
      new_state = release_ip(state, chaddr, requested_ip)
      {new_state, []}
    else
      {state, []}
    end
  end

  defp handle_release(state, message) do
    chaddr = extract_client_mac(message)
    requested_ip = message.ciaddr

    new_state = release_ip(state, chaddr, requested_ip)
    {new_state, []}
  end

  defp handle_inform(state, message) do
    # No IP assigned in INFORM
    response = build_ack(state, message, nil)
    {state, [response]}
  end

  ## Lease Management

  defp find_or_create_lease(state, chaddr, message) do
    case Map.get(state.leases, chaddr) do
      nil ->
        allocate_new_lease(state, chaddr, message)

      lease ->
        if lease.expires_at > System.system_time(:second) do
          {:ok, lease, state}
        else
          new_state = release_ip(state, chaddr, lease.ip)
          allocate_new_lease(new_state, chaddr, message)
        end
    end
  end

  defp allocate_new_lease(state, chaddr, message) do
    available_ips = MapSet.difference(state.ip_pool, state.used_ips)

    if MapSet.size(available_ips) > 0 do
      ip = choose_ip(available_ips, message)
      lease_time = state.config.lease_time

      lease = %{
        ip: ip,
        mac: chaddr,
        expires_at: System.system_time(:second) + lease_time,
        client_id: find_client_id(message),
        hostname: find_hostname(message),
        options: state.config.options
      }

      new_state = %{
        state
        | leases: Map.put(state.leases, chaddr, lease),
          used_ips: MapSet.put(state.used_ips, ip)
      }

      {:ok, lease, new_state}
    else
      {:error, :no_available_ips}
    end
  end

  defp validate_lease(state, chaddr, message) do
    requested_ip = find_requested_ip(message)
    server_id = find_server_id(message)

    cond do
      server_id && server_id != state.config.gateway ->
        {:error, :wrong_server}

      requested_ip && !MapSet.member?(state.ip_pool, requested_ip) ->
        {:error, :invalid_ip}

      requested_ip && !ip_available?(state, requested_ip, chaddr) ->
        {:error, :ip_not_available}

      true ->
        case Map.get(state.leases, chaddr) do
          nil -> allocate_new_lease(state, chaddr, message)
          lease -> {:ok, lease, state}
        end
    end
  end

  defp release_ip(state, chaddr, ip) do
    case Map.get(state.leases, chaddr) do
      %{ip: ^ip} ->
        %{
          state
          | leases: Map.delete(state.leases, chaddr),
            used_ips: MapSet.delete(state.used_ips, ip)
        }

      _ ->
        state
    end
  end

  ## Message Building

  defp build_offer(state, request, lease) do
    Message.new()
    # BOOTREPLY
    |> Map.put(:op, 2)
    |> Map.put(:htype, request.htype)
    |> Map.put(:hlen, request.hlen)
    |> Map.put(:xid, request.xid)
    |> Map.put(:yiaddr, lease.ip)
    |> Map.put(:siaddr, state.config.gateway || {0, 0, 0, 0})
    |> Map.put(:chaddr, request.chaddr)
    # DHCPOFFER
    |> add_dhcp_options(0, lease, 2, state)
  end

  defp build_ack(state, request, lease) do
    Message.new()
    # BOOTREPLY
    |> Map.put(:op, 2)
    |> Map.put(:htype, request.htype)
    |> Map.put(:hlen, request.hlen)
    |> Map.put(:xid, request.xid)
    |> Map.put(:yiaddr, (lease && lease.ip) || {0, 0, 0, 0})
    |> Map.put(:siaddr, state.config.gateway || {0, 0, 0, 0})
    |> Map.put(:chaddr, request.chaddr)
    # DHCPACK
    |> add_dhcp_options(0, lease, 5, state)
  end

  defp build_nak(request, message) do
    Message.new()
    # BOOTREPLY
    |> Map.put(:op, 2)
    |> Map.put(:htype, request.htype)
    |> Map.put(:hlen, request.hlen)
    |> Map.put(:xid, request.xid)
    |> Map.put(:chaddr, request.chaddr)
    # DHCPNAK
    |> add_option(53, 1, <<6>>)
    |> add_option(56, byte_size(message), message)
  end

  defp add_dhcp_options(message, _request, _lease, message_type, state) do
    gateway = state.config.gateway || {0, 0, 0, 0}

    message
    |> add_option(53, 1, <<message_type>>)
    |> add_option(54, 4, ip_to_binary(gateway))
    |> add_option(51, 4, <<state.config.lease_time::32>>)
    |> add_option(1, 4, ip_to_binary(state.config.netmask))
    |> maybe_add_option(3, 4, gateway, :ip)
    |> maybe_add_option(
      6,
      length(state.config.dns_servers) * 4,
      state.config.dns_servers,
      :ip_list
    )
    |> add_server_options(state)
  end

  defp add_option(message, type, length, value) do
    option = Option.new(type, length, value)
    %{message | options: [option | message.options]}
  end

  defp maybe_add_option(message, _type, _length, nil, _format), do: message

  defp maybe_add_option(message, type, length, value, format) do
    binary_value = encode_option_value(value, format)
    add_option(message, type, length, binary_value)
  end

  defp add_server_options(message, state) do
    message
    |> Map.update!(:options, fn options -> options ++ state.config.options end)
  end

  ## Helper Functions

  defp generate_ip_pool(start_ip, end_ip) do
    start_int = ip_to_int(start_ip)
    end_int = ip_to_int(end_ip)

    Enum.reduce(start_int..end_int, MapSet.new(), fn ip_int, acc ->
      MapSet.put(acc, int_to_ip(ip_int))
    end)
  end

  defp choose_ip(available_ips, message) do
    requested_ip = find_requested_ip(message)

    cond do
      requested_ip && MapSet.member?(available_ips, requested_ip) -> requested_ip
      true -> MapSet.to_list(available_ips) |> List.first()
    end
  end

  defp ip_available?(state, ip, chaddr) do
    case Map.get(state.leases, chaddr) do
      %{ip: ^ip} -> true
      _ -> !MapSet.member?(state.used_ips, ip)
    end
  end

  defp get_message_type(message) do
    Enum.find_value(message.options, 0, fn option ->
      if option.type == 53, do: :binary.decode_unsigned(option.value), else: nil
    end)
  end

  defp extract_client_mac(message) do
    :binary.part(message.chaddr, 0, message.hlen)
  end

  defp find_requested_ip(message) do
    Enum.find_value(message.options, fn option ->
      if option.type == 50, do: binary_to_ip(option.value), else: nil
    end)
  end

  defp find_server_id(message) do
    Enum.find_value(message.options, fn option ->
      if option.type == 54, do: binary_to_ip(option.value), else: nil
    end)
  end

  defp find_client_id(message) do
    Enum.find_value(message.options, fn option ->
      if option.type == 61, do: option.value, else: nil
    end)
  end

  defp find_hostname(message) do
    Enum.find_value(message.options, fn option ->
      if option.type == 12, do: option.value |> String.trim(<<0>>), else: nil
    end)
  end

  defp ip_to_int({a, b, c, d}),
    do: Bitwise.bsl(a, 24) ||| Bitwise.bsl(b, 16) ||| Bitwise.bsl(c, 8) ||| d

  defp int_to_ip(int),
    do:
      {Bitwise.bsr(int, 24) &&& 0xFF, Bitwise.bsr(int, 16) &&& 0xFF, Bitwise.bsr(int, 8) &&& 0xFF,
       int &&& 0xFF}

  defp ip_to_binary({a, b, c, d}), do: <<a, b, c, d>>
  defp binary_to_ip(<<a, b, c, d>>), do: {a, b, c, d}

  defp encode_option_value(value, :ip), do: ip_to_binary(value)

  defp encode_option_value(values, :ip_list) when is_list(values) do
    Enum.reduce(values, <<>>, fn ip, acc -> <<acc::binary, ip_to_binary(ip)::binary>> end)
  end
end
