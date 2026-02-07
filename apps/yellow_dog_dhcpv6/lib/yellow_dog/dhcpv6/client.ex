defmodule YellowDog.Dhcpv6.Client do
  @moduledoc """
  DHCPv6 client for sending DHCPv6 requests.

  Wraps the `DHCPv6.Client` message building functions and uses UDP transport
  for IPv6 multicast. Suitable for testing DHCPv6 servers or implementing DHCPv6 clients.

  ## Usage

      # Create and send a SOLICIT message
      duid = <<0, 1, 0, 1, ...>>  # Client DUID
      iaid = 12345
      {:ok, advertise} = YellowDog.Dhcpv6.Client.solicit(duid: duid, iaid: iaid)

      # Send a pre-built message
      message = DHCPv6.Client.request(duid: duid, server_duid: server_duid, iaid: iaid, addresses: addrs)
      {:ok, response} = YellowDog.Dhcpv6.Client.send_message(message)

      # Run a complete lease cycle
      {:ok, result} = YellowDog.Dhcpv6.Client.lease_cycle(duid: duid, iaid: iaid)
  """

  alias DHCPv6.Message

  # All DHCP Relay Agents and Servers multicast address
  @default_multicast_addr {0xFF02, 0, 0, 0, 0, 0, 0x0001, 0x0002}
  @default_server_port 547
  @default_client_port 546
  @default_timeout 5000

  @typedoc "Client options for DHCPv6 operations"
  @type client_opts :: [
          server: :inet.ip6_address(),
          server_port: :inet.port_number(),
          client_port: :inet.port_number(),
          timeout: non_neg_integer(),
          interface: String.t()
        ]

  @doc """
  Create and send a DHCPv6 SOLICIT message.

  ## Parameters

  - `opts` - Keyword list:
    - `:duid` - Client DUID (required)
    - `:iaid` - Identity Association ID (required)
    - `:transaction_id` - Transaction ID (auto-generated if not provided)
    - `:rapid_commit` - Include rapid commit option (default: false)
    - `:dns_servers` - Request DNS servers (default: true)
    - `:server` - Server IP (default: ff02::1:2)
    - `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

  - `{:ok, %DHCPv6.Message{}}` - ADVERTISE response
  - `{:error, reason}` - Error

  ## Examples

      duid = DHCP.SecureRandom.generate_duid_llt()
      iaid = DHCP.SecureRandom.generate_ia_id()
      {:ok, advertise} = YellowDog.Dhcpv6.Client.solicit(duid: duid, iaid: iaid)
  """
  @spec solicit(keyword()) :: {:ok, Message.t()} | {:error, term()}
  def solicit(opts) do
    message = DHCPv6.Client.solicit(opts)
    send_and_receive(message, opts)
  end

  @doc """
  Create and send a DHCPv6 REQUEST message.

  ## Parameters

  - `opts` - Keyword list:
    - `:duid` - Client DUID (required)
    - `:server_duid` - Server DUID (required)
    - `:iaid` - Identity Association ID (required)
    - `:addresses` - Requested IPv6 addresses (required)
    - `:transaction_id` - Transaction ID (auto-generated if not provided)
    - `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

  - `{:ok, %DHCPv6.Message{}}` - REPLY response
  - `{:error, reason}` - Error
  """
  @spec request(keyword()) :: {:ok, Message.t()} | {:error, term()}
  def request(opts) do
    message = DHCPv6.Client.request(opts)
    send_and_receive(message, opts)
  end

  @doc """
  Create and send a DHCPv6 RENEW message.

  ## Parameters

  - `opts` - Keyword list:
    - `:duid` - Client DUID (required)
    - `:server_duid` - Server DUID (required)
    - `:iaid` - Identity Association ID (required)
    - `:addresses` - IPv6 addresses to renew (required)
    - `:transaction_id` - Transaction ID (auto-generated if not provided)
    - `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

  - `{:ok, %DHCPv6.Message{}}` - REPLY response
  - `{:error, reason}` - Error
  """
  @spec renew(keyword()) :: {:ok, Message.t()} | {:error, term()}
  def renew(opts) do
    message = DHCPv6.Client.renew(opts)
    send_and_receive(message, opts)
  end

  @doc """
  Create and send a DHCPv6 RELEASE message.

  ## Parameters

  - `opts` - Keyword list:
    - `:duid` - Client DUID (required)
    - `:server_duid` - Server DUID (required)
    - `:iaid` - Identity Association ID (required)
    - `:addresses` - IPv6 addresses to release (required)
    - `:transaction_id` - Transaction ID (auto-generated if not provided)
    - `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

  - `{:ok, %DHCPv6.Message{}}` - REPLY response (acknowledgement)
  - `{:error, reason}` - Error
  """
  @spec release(keyword()) :: {:ok, Message.t()} | {:error, term()}
  def release(opts) do
    message = DHCPv6.Client.release(opts)
    send_and_receive(message, opts)
  end

  @doc """
  Create and send a DHCPv6 INFORMATION-REQUEST message.

  Used to obtain configuration parameters without requesting an address.

  ## Parameters

  - `opts` - Keyword list:
    - `:duid` - Client DUID (required)
    - `:transaction_id` - Transaction ID (auto-generated if not provided)
    - `:dns_servers` - Request DNS servers (default: true)
    - `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

  - `{:ok, %DHCPv6.Message{}}` - REPLY response with configuration
  - `{:error, reason}` - Error
  """
  @spec information_request(keyword()) :: {:ok, Message.t()} | {:error, term()}
  def information_request(opts) do
    message = DHCPv6.Client.information_request(opts)
    send_and_receive(message, opts)
  end

  @doc """
  Send a pre-built DHCPv6 message and wait for response.

  ## Parameters

  - `message` - `%DHCPv6.Message{}` struct
  - `opts` - Optional keyword list:
    - `:server` - Server IP (default: ff02::1:2)
    - `:server_port` - Server port (default: 547)
    - `:client_port` - Client port to bind (default: 546)
    - `:timeout` - Timeout in milliseconds (default: 5000)
    - `:interface` - Network interface for multicast (optional)

  ## Returns

  - `{:ok, %DHCPv6.Message{}}` - Parsed response
  - `{:error, reason}` - Error
  """
  @spec send_message(Message.t(), client_opts()) :: {:ok, Message.t()} | {:error, term()}
  def send_message(message, opts \\ []) do
    send_and_receive(message, opts)
  end

  @doc """
  Send a pre-built DHCPv6 message without waiting for response.

  ## Parameters

  - `message` - `%DHCPv6.Message{}` struct
  - `opts` - Optional keyword list (same as `send_message/2`)

  ## Returns

  - `:ok` - Message sent
  - `{:error, reason}` - Error
  """
  @spec send_message_async(Message.t(), client_opts()) :: :ok | {:error, term()}
  def send_message_async(message, opts \\ []) do
    send_only(message, opts)
  end

  @doc """
  Run a complete DHCPv6 lease cycle (SOLICIT → ADVERTISE → REQUEST → REPLY).

  ## Parameters

  - `opts` - Keyword list:
    - `:duid` - Client DUID (required)
    - `:iaid` - Identity Association ID (required)
    - `:server` - Server IP (default: ff02::1:2)
    - `:timeout` - Timeout per message (default: 5000)

  ## Returns

  - `{:ok, map}` - Map with :solicit, :advertise, :request, :reply messages
  - `{:error, reason}` - Error at any step
  """
  @spec lease_cycle(keyword()) :: {:ok, map()} | {:error, term()}
  def lease_cycle(opts) do
    duid = Keyword.fetch!(opts, :duid)
    iaid = Keyword.fetch!(opts, :iaid)

    with {:ok, advertise} <- solicit(opts),
         server_duid <- extract_server_duid(advertise),
         addresses <- extract_addresses(advertise),
         request_opts <-
           Keyword.merge(opts,
             duid: duid,
             server_duid: server_duid,
             iaid: iaid,
             addresses: addresses
           ),
         {:ok, reply} <- request(request_opts) do
      {:ok,
       %{
         solicit: DHCPv6.Client.solicit(duid: duid, iaid: iaid),
         advertise: advertise,
         request:
           DHCPv6.Client.request(
             duid: duid,
             server_duid: server_duid,
             iaid: iaid,
             addresses: addresses
           ),
         reply: reply
       }}
    end
  end

  # Private functions

  defp send_and_receive(message, opts) do
    server = Keyword.get(opts, :server, @default_multicast_addr)
    server_port = Keyword.get(opts, :server_port, @default_server_port)
    client_port = Keyword.get(opts, :client_port, @default_client_port)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    binary = DHCPv6.Message.to_iodata(message) |> IO.iodata_to_binary()

    socket_opts = [:binary, {:active, false}, :inet6]

    socket_opts =
      case Keyword.get(opts, :interface) do
        nil -> socket_opts
        iface -> [{:multicast_if, iface} | socket_opts]
      end

    case :gen_udp.open(client_port, socket_opts) do
      {:ok, socket} ->
        try do
          case :gen_udp.send(socket, server, server_port, binary) do
            :ok ->
              case :gen_udp.recv(socket, 0, timeout) do
                {:ok, {_ip, _port, response}} ->
                  parse_response(response)

                {:error, :timeout} ->
                  {:error, :timeout}

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end
        after
          :gen_udp.close(socket)
        end

      {:error, :eaddrinuse} ->
        # Port 546 might be in use, try ephemeral port
        send_and_receive_ephemeral(binary, server, server_port, timeout, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_and_receive_ephemeral(binary, server, server_port, timeout, opts) do
    socket_opts = [:binary, {:active, false}, :inet6]

    socket_opts =
      case Keyword.get(opts, :interface) do
        nil -> socket_opts
        iface -> [{:multicast_if, iface} | socket_opts]
      end

    case :gen_udp.open(0, socket_opts) do
      {:ok, socket} ->
        try do
          case :gen_udp.send(socket, server, server_port, binary) do
            :ok ->
              case :gen_udp.recv(socket, 0, timeout) do
                {:ok, {_ip, _port, response}} ->
                  parse_response(response)

                {:error, :timeout} ->
                  {:error, :timeout}

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_only(message, opts) do
    server = Keyword.get(opts, :server, @default_multicast_addr)
    server_port = Keyword.get(opts, :server_port, @default_server_port)

    binary = DHCPv6.Message.to_iodata(message) |> IO.iodata_to_binary()

    socket_opts = [:binary, {:active, false}, :inet6]

    socket_opts =
      case Keyword.get(opts, :interface) do
        nil -> socket_opts
        iface -> [{:multicast_if, iface} | socket_opts]
      end

    case :gen_udp.open(0, socket_opts) do
      {:ok, socket} ->
        result = :gen_udp.send(socket, server, server_port, binary)
        :gen_udp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(response_binary) do
    try do
      message = Message.from_iodata(response_binary)
      {:ok, message}
    rescue
      e -> {:error, {:parse_error, Exception.message(e)}}
    catch
      :throw, reason ->
        {:error, {:parse_error, inspect(reason)}}
    end
  end

  defp extract_server_duid(advertise) do
    # Get server identifier from options (option code 2 = SERVERID)
    server_opt =
      Enum.find(advertise.options, fn opt ->
        opt.option_code == 2
      end)

    case server_opt do
      %{option_data: duid} -> duid
      _ -> nil
    end
  end

  defp extract_addresses(message) do
    # Extract addresses from IA_NA options (option code 3)
    for %{option_code: 3, option_data: <<_iaid::32, _t1::32, _t2::32, rest::binary>>} <-
          message.options,
        addr <- parse_ia_addresses(rest),
        do: addr
  end

  defp parse_ia_addresses(data) do
    parse_ia_addresses(data, [])
  end

  defp parse_ia_addresses(<<>>, acc), do: Enum.reverse(acc)

  defp parse_ia_addresses(
         <<5::16, option_length::16, addr_data::binary-size(option_length), rest::binary>>,
         acc
       ) do
    case parse_ipv6_address(addr_data) do
      {:ok, addr} -> parse_ia_addresses(rest, [addr | acc])
      {:error, _} -> parse_ia_addresses(rest, acc)
    end
  end

  defp parse_ia_addresses(_, acc), do: Enum.reverse(acc)

  defp parse_ipv6_address(
         <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, _rest::binary>>
       ) do
    {:ok, {a, b, c, d, e, f, g, h}}
  end

  defp parse_ipv6_address(_), do: {:error, :invalid_ipv6}
end
