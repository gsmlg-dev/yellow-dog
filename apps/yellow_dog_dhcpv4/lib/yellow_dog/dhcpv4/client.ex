defmodule YellowDog.Dhcpv4.Client do
  @moduledoc """
  DHCPv4 client for sending DHCP requests.

  Wraps the `DHCPv4.Client` message building functions and uses `Abyss.Client`
  for UDP transport. Suitable for testing DHCP servers or implementing DHCP clients.

  ## Usage

      # Create and send a DHCP DISCOVER
      mac = <<0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>
      {:ok, offer} = YellowDog.Dhcpv4.Client.discover(mac: mac)

      # Send a pre-built message
      message = DHCPv4.Client.request(mac: mac, server_ip: server, requested_ip: ip)
      {:ok, response} = YellowDog.Dhcpv4.Client.send_message(message)

      # Run a complete lease cycle
      {:ok, result} = YellowDog.Dhcpv4.Client.lease_cycle(mac: mac)
  """

  alias DHCPv4.Message

  @default_server_port 67
  @default_client_port 68
  @default_timeout 5000
  @broadcast_addr {255, 255, 255, 255}

  @typedoc "Client options for DHCP operations"
  @type client_opts :: [
          server: :inet.ip_address(),
          server_port: :inet.port_number(),
          client_port: :inet.port_number(),
          timeout: non_neg_integer(),
          source: :inet.ip_address()
        ]

  @doc """
  Create and send a DHCP DISCOVER message.

  ## Parameters

  - `opts` - Keyword list:
    - `:mac` - Client MAC address (required, 6 bytes binary)
    - `:hostname` - Hostname to include (optional)
    - `:requested_ip` - IP to request (optional)
    - `:xid` - Transaction ID (auto-generated if not provided)
    - `:server` - Server IP (default: 255.255.255.255)
    - `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

  - `{:ok, %DHCPv4.Message{}}` - DHCP OFFER response
  - `{:error, reason}` - Error

  ## Examples

      mac = <<0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>
      {:ok, offer} = YellowDog.Dhcpv4.Client.discover(mac: mac)
  """
  @spec discover(keyword()) :: {:ok, Message.t()} | {:error, term()}
  def discover(opts) do
    message = DHCPv4.Client.discover(opts)
    send_and_receive(message, opts)
  end

  @doc """
  Create and send a DHCP REQUEST message.

  ## Parameters

  - `opts` - Keyword list:
    - `:mac` - Client MAC address (required)
    - `:server_ip` - Server IP to request from (required)
    - `:requested_ip` - IP to request (required)
    - `:xid` - Transaction ID (auto-generated if not provided)
    - `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

  - `{:ok, %DHCPv4.Message{}}` - DHCP ACK/NAK response
  - `{:error, reason}` - Error
  """
  @spec request(keyword()) :: {:ok, Message.t()} | {:error, term()}
  def request(opts) do
    message = DHCPv4.Client.request(opts)
    send_and_receive(message, opts)
  end

  @doc """
  Create and send a DHCP RELEASE message.

  ## Parameters

  - `opts` - Keyword list:
    - `:mac` - Client MAC address (required)
    - `:server_ip` - Server IP to release to (required)
    - `:leased_ip` - IP to release (required)
    - `:xid` - Transaction ID (auto-generated if not provided)

  ## Returns

  - `:ok` - Release sent (no response expected)
  - `{:error, reason}` - Error
  """
  @spec release(keyword()) :: :ok | {:error, term()}
  def release(opts) do
    message = DHCPv4.Client.release(opts)
    send_only(message, opts)
  end

  @doc """
  Create and send a DHCP DECLINE message.

  ## Parameters

  - `opts` - Keyword list:
    - `:mac` - Client MAC address (required)
    - `:server_ip` - Server IP to decline from (required)
    - `:declined_ip` - IP to decline (required)
    - `:xid` - Transaction ID (auto-generated if not provided)

  ## Returns

  - `:ok` - Decline sent (no response expected)
  - `{:error, reason}` - Error
  """
  @spec decline(keyword()) :: :ok | {:error, term()}
  def decline(opts) do
    message = DHCPv4.Client.decline(opts)
    send_only(message, opts)
  end

  @doc """
  Send a pre-built DHCP message and wait for response.

  ## Parameters

  - `message` - `%DHCPv4.Message{}` struct
  - `opts` - Optional keyword list:
    - `:server` - Server IP (default: 255.255.255.255)
    - `:server_port` - Server port (default: 67)
    - `:client_port` - Client port to bind (default: 68)
    - `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

  - `{:ok, %DHCPv4.Message{}}` - Parsed response
  - `{:error, reason}` - Error
  """
  @spec send_message(Message.t(), client_opts()) :: {:ok, Message.t()} | {:error, term()}
  def send_message(message, opts \\ []) do
    send_and_receive(message, opts)
  end

  @doc """
  Send a pre-built DHCP message without waiting for response.

  Useful for RELEASE and DECLINE messages that don't expect a response.

  ## Parameters

  - `message` - `%DHCPv4.Message{}` struct
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
  Run a complete DHCP lease cycle (DISCOVER → OFFER → REQUEST → ACK).

  ## Parameters

  - `opts` - Keyword list:
    - `:mac` - Client MAC address (required)
    - `:server` - Server IP (default: 255.255.255.255)
    - `:timeout` - Timeout per message (default: 5000)

  ## Returns

  - `{:ok, map}` - Map with :discover, :offer, :request, :ack messages
  - `{:error, reason}` - Error at any step
  """
  @spec lease_cycle(keyword()) :: {:ok, map()} | {:error, term()}
  def lease_cycle(opts) do
    mac = Keyword.fetch!(opts, :mac)

    with {:ok, offer} <- discover(opts),
         server_ip <- extract_server_ip(offer),
         requested_ip <- offer.yiaddr,
         request_opts <-
           Keyword.merge(opts, mac: mac, server_ip: server_ip, requested_ip: requested_ip),
         {:ok, ack} <- request(request_opts) do
      {:ok,
       %{
         discover: DHCPv4.Client.discover(mac: mac),
         offer: offer,
         request:
           DHCPv4.Client.request(mac: mac, server_ip: server_ip, requested_ip: requested_ip),
         ack: ack
       }}
    end
  end

  # Private functions

  defp send_and_receive(message, opts) do
    server = Keyword.get(opts, :server, @broadcast_addr)
    server_port = Keyword.get(opts, :server_port, @default_server_port)
    client_port = Keyword.get(opts, :client_port, @default_client_port)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    binary = DHCP.to_iodata(message) |> IO.iodata_to_binary()

    # DHCP requires binding to specific client port and using broadcast
    # We need to use raw gen_udp for proper DHCP protocol handling
    socket_opts = [:binary, {:active, false}, {:broadcast, true}]

    socket_opts =
      case Keyword.get(opts, :source) do
        nil -> socket_opts
        source -> [{:ip, source} | socket_opts]
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
        # Port 68 might be in use, try ephemeral port
        send_and_receive_ephemeral(binary, server, server_port, timeout, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_and_receive_ephemeral(binary, server, server_port, timeout, opts) do
    socket_opts = [:binary, {:active, false}, {:broadcast, true}]

    socket_opts =
      case Keyword.get(opts, :source) do
        nil -> socket_opts
        source -> [{:ip, source} | socket_opts]
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
    server = Keyword.get(opts, :server, @broadcast_addr)
    server_port = Keyword.get(opts, :server_port, @default_server_port)

    binary = DHCP.to_iodata(message) |> IO.iodata_to_binary()

    # Use Abyss.Client.broadcast for send-only operations
    Abyss.Client.broadcast(server, server_port, binary)
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

  defp extract_server_ip(offer) do
    # Try to get server identifier from options (option 54)
    server_opt =
      Enum.find(offer.options, fn opt ->
        opt.type == 54
      end)

    case server_opt do
      %{value: <<a, b, c, d>>} -> {a, b, c, d}
      _ -> offer.siaddr
    end
  end
end
