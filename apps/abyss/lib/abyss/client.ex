defmodule Abyss.Client do
  @moduledoc """
  Stateless UDP client for outbound packet transmission and request-response operations.

  Provides client capabilities for unicast and broadcast operations, as well as
  request-response patterns for protocols like DNS. Each call opens an ephemeral
  socket, performs the operation, and closes the socket.

  ## Features

  - **Stateless** - No connection state or socket lifecycle management
  - **Explicit** - Caller provides all addressing parameters
  - **Request-Response** - `send_recv/5` for unicast query protocols (DNS)
  - **Broadcast** - `broadcast/4` for send-only multicast/broadcast
  - **Subscribe** - `subscribe_broadcast/4` for receive-only multicast/broadcast
  - **Telemetry integrated** - Consistent with Abyss server telemetry patterns

  ## Usage Examples

  ### DNS Query (Request-Response)

      # Query DNS server with timeout
      query_packet = DNS.encode(query)
      {:ok, response} = Abyss.Client.send_recv({8, 8, 8, 8}, 53, query_packet, 5000)

      # With source binding
      {:ok, response} = Abyss.Client.send_recv({8, 8, 8, 8}, 53, query_packet, 5000,
        source: {192, 168, 1, 10})

  ### DNS Forwarding (Fire-and-Forget)

      # Forward query to upstream resolver
      query_packet = DNS.encode(query)
      Abyss.Client.send({8, 8, 8, 8}, 53, query_packet)

  ### mDNS Announcements (Send-only Broadcast)

      # Multicast announcement
      announcement = MDNS.encode(response)
      Abyss.Client.broadcast({224, 0, 0, 251}, 5353, announcement,
        source: {192, 168, 1, 10},
        interface: "eth0"
      )

  ### mDNS Discovery (Receive-only Subscribe)

      # Subscribe to multicast and collect responses for 2 seconds
      {:ok, responses} = Abyss.Client.subscribe_broadcast({224, 0, 0, 251}, 5353, 2000,
        source: {192, 168, 1, 10})

  ### DHCPv4 Responses

      # DHCPOFFER via limited broadcast
      offer_packet = DHCP.encode(offer)
      Abyss.Client.broadcast({255, 255, 255, 255}, 68, offer_packet,
        source: {192, 168, 1, 1},
        interface: "eth0"
      )
  """

  @typedoc "Destination host - IP address or hostname"
  @type host :: :inet.ip_address() | :inet.hostname()

  @typedoc "Port number"
  @type port_number :: :inet.port_number()

  @typedoc "Binary packet data"
  @type packet :: binary()

  @typedoc "Broadcast address - IP address for broadcast or multicast"
  @type broadcast_addr :: :inet.ip_address()

  @typedoc """
  Client options.

  - `:source` - Source IP address to bind the socket to
  - `:interface` - Network interface name (e.g., "eth0") for interface binding
  - `:ttl` - Time-to-live for multicast packets (default: 1 for link-local)
  - `:bind_port` - Port to bind the socket to (default: 0 for ephemeral)
  """
  @type opts :: [
          source: :inet.ip_address(),
          interface: String.t(),
          ttl: non_neg_integer(),
          bind_port: :inet.port_number()
        ]

  @typedoc "POSIX error reason"
  @type reason :: :inet.posix()

  # Multicast address range is 224.0.0.0/4 (224.0.0.0 - 239.255.255.255)

  @doc """
  Send a UDP packet and wait for a response (request-response pattern).

  Opens an ephemeral socket, sends the packet, waits for a response up to the
  specified timeout, and closes the socket. This is useful for protocols like
  DNS that expect a response to each query.

  ## Parameters

  - `host` - Destination IP address or hostname
  - `port` - Destination port number
  - `packet` - Binary data to send
  - `timeout` - Timeout in milliseconds to wait for response
  - `opts` - Optional keyword list:
    - `:source` - Source IP address to bind
    - `:interface` - Network interface name (e.g., "eth0")

  ## Returns

  - `{:ok, response}` - Response binary data received
  - `{:error, :timeout}` - No response within timeout
  - `{:error, reason}` - POSIX error

  ## Examples

      # DNS query with 5 second timeout
      iex> Abyss.Client.send_recv({8, 8, 8, 8}, 53, dns_query, 5000)
      {:ok, <<...response...>>}

      iex> Abyss.Client.send_recv({8, 8, 8, 8}, 53, dns_query, 5000, source: {192, 168, 1, 10})
      {:ok, <<...response...>>}
  """
  @spec send_recv(host(), port_number(), packet(), timeout :: non_neg_integer(), opts()) ::
          {:ok, binary()} | {:error, reason() | :timeout}
  def send_recv(host, port, packet, timeout, opts \\ []) do
    metadata = %{
      host: host,
      port: port,
      size: byte_size(packet),
      type: :request_response,
      timeout: timeout
    }

    start_time = System.monotonic_time()
    :telemetry.execute([:abyss, :client, :send_recv, :start], %{}, metadata)

    # Use {:active, false} for synchronous receive
    socket_opts = [:binary, {:active, false} | build_socket_opts(opts, _broadcast = false)]

    result =
      with {:ok, socket} <- :gen_udp.open(0, socket_opts),
           :ok <- :gen_udp.send(socket, host, port, packet),
           {:ok, {_from_ip, _from_port, response}} <- :gen_udp.recv(socket, 0, timeout) do
        :gen_udp.close(socket)
        {:ok, response}
      else
        {:error, _reason} = error ->
          error

        other ->
          {:error, other}
      end

    emit_send_recv_telemetry(result, start_time, metadata)
    result
  end

  @doc """
  Subscribe to a multicast/broadcast address and collect incoming packets.

  Opens an ephemeral socket, joins multicast group if needed, and collects
  incoming packets for the specified timeout duration. This is receive-only
  and does not send any packets.

  ## Parameters

  - `broadcast_addr` - Broadcast or multicast IP address to subscribe to
  - `port` - Port number to listen on
  - `timeout` - Timeout in milliseconds to collect responses
  - `opts` - Optional keyword list:
    - `:source` - Source IP address to bind (used for multicast interface)
    - `:interface` - Network interface name (e.g., "eth0")

  ## Returns

  - `{:ok, [packet]}` - List of received packet binaries (may be empty)
  - `{:error, reason}` - POSIX error

  ## Examples

      # Subscribe to mDNS multicast and collect packets for 2 seconds
      iex> Abyss.Client.subscribe_broadcast({224, 0, 0, 251}, 5353, 2000)
      {:ok, [<<...packet1...>>, <<...packet2...>>]}

      # With interface binding
      iex> Abyss.Client.subscribe_broadcast({224, 0, 0, 251}, 5353, 2000,
      ...>   source: {192, 168, 1, 10})
      {:ok, [<<...packet1...>>]}
  """
  @spec subscribe_broadcast(
          broadcast_addr(),
          port_number(),
          timeout :: non_neg_integer(),
          opts()
        ) ::
          {:ok, [binary()]} | {:error, reason()}
  def subscribe_broadcast(broadcast_addr, port, timeout, opts \\ []) do
    metadata = %{
      host: broadcast_addr,
      port: port,
      type: :subscribe_broadcast,
      timeout: timeout
    }

    start_time = System.monotonic_time()
    :telemetry.execute([:abyss, :client, :subscribe, :start], %{}, metadata)

    # For subscribe, we need to bind to the actual port and enable reuseaddr
    socket_opts = [
      :binary,
      {:active, false},
      {:reuseaddr, true} | build_socket_opts(opts, _broadcast = true, broadcast_addr)
    ]

    result =
      with {:ok, socket} <- :gen_udp.open(port, socket_opts),
           :ok <- maybe_join_multicast(socket, broadcast_addr, opts) do
        packets = collect_responses(socket, timeout, [])
        :gen_udp.close(socket)
        {:ok, packets}
      end

    emit_subscribe_telemetry(result, start_time, metadata)
    result
  end

  # Collect responses until timeout
  defp collect_responses(socket, timeout, acc) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_responses(socket, deadline, acc)
  end

  defp do_collect_responses(socket, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      case :gen_udp.recv(socket, 0, remaining) do
        {:ok, {_from_ip, _from_port, response}} ->
          do_collect_responses(socket, deadline, [response | acc])

        {:error, :timeout} ->
          Enum.reverse(acc)

        {:error, _reason} ->
          Enum.reverse(acc)
      end
    end
  end

  # Join multicast group if the address is a multicast address
  defp maybe_join_multicast(socket, addr, opts) do
    if multicast_address?(addr) do
      source = opts[:source] || {0, 0, 0, 0}
      :inet.setopts(socket, [{:add_membership, {addr, source}}])
    else
      :ok
    end
  end

  @doc """
  Send a unicast UDP packet to the specified host and port.

  Opens an ephemeral socket, sends the packet, and closes the socket.

  ## Parameters

  - `host` - Destination IP address or hostname
  - `port` - Destination port number
  - `packet` - Binary data to send
  - `opts` - Optional keyword list:
    - `:source` - Source IP address to bind
    - `:interface` - Network interface name (e.g., "eth0")

  ## Returns

  - `:ok` - Packet sent successfully
  - `{:error, reason}` - POSIX error

  ## Examples

      iex> Abyss.Client.send({8, 8, 8, 8}, 53, <<0, 1, 2, 3>>)
      :ok

      iex> Abyss.Client.send({8, 8, 8, 8}, 53, <<0, 1, 2, 3>>, source: {192, 168, 1, 10})
      :ok
  """
  @spec send(host(), port_number(), packet(), opts()) :: :ok | {:error, reason()}
  def send(host, port, packet, opts \\ []) do
    metadata = %{
      host: host,
      port: port,
      size: byte_size(packet),
      type: :unicast
    }

    start_time = System.monotonic_time()
    :telemetry.execute([:abyss, :client, :send, :start], %{}, metadata)

    socket_opts = build_socket_opts(opts, _broadcast = false)

    result =
      with {:ok, socket} <- :gen_udp.open(0, socket_opts),
           :ok <- :gen_udp.send(socket, host, port, packet) do
        :gen_udp.close(socket)
        :ok
      end

    emit_result_telemetry(result, start_time, metadata)
    result
  end

  @doc """
  Send a broadcast UDP packet to the specified broadcast address and port.

  Opens an ephemeral socket with broadcast enabled, sends the packet, and closes the socket.
  Works with limited broadcast (255.255.255.255), directed broadcast (e.g., 192.168.1.255),
  and multicast addresses (e.g., 224.0.0.251 for mDNS).

  ## Parameters

  - `broadcast_addr` - Broadcast or multicast IP address (mandatory, no default)
    - Limited broadcast: `{255, 255, 255, 255}`
    - Directed broadcast: `{192, 168, 1, 255}` (subnet-specific)
    - Multicast: `{224, 0, 0, 251}` (mDNS)
  - `port` - Destination port number
  - `packet` - Binary data to send
  - `opts` - Optional keyword list:
    - `:source` - Source IP address to bind
    - `:interface` - Network interface name (required for most broadcast scenarios)
    - `:ttl` - Time-to-live for multicast (default: 1 for link-local)

  ## Returns

  - `:ok` - Packet sent successfully
  - `{:error, reason}` - POSIX error

  ## Examples

      # Limited broadcast
      iex> Abyss.Client.broadcast({255, 255, 255, 255}, 68, dhcp_packet,
      ...>   source: {192, 168, 1, 1}, interface: "eth0")
      :ok

      # Multicast (mDNS)
      iex> Abyss.Client.broadcast({224, 0, 0, 251}, 5353, mdns_packet,
      ...>   source: {192, 168, 1, 10}, interface: "eth0")
      :ok
  """
  @spec broadcast(broadcast_addr(), port_number(), packet(), opts()) :: :ok | {:error, reason()}
  def broadcast(broadcast_addr, port, packet, opts \\ []) do
    metadata = %{
      host: broadcast_addr,
      port: port,
      size: byte_size(packet),
      type: :broadcast
    }

    start_time = System.monotonic_time()
    :telemetry.execute([:abyss, :client, :send, :start], %{}, metadata)

    socket_opts = build_socket_opts(opts, _broadcast = true, broadcast_addr)

    result =
      with {:ok, socket} <- :gen_udp.open(0, socket_opts),
           :ok <- :gen_udp.send(socket, broadcast_addr, port, packet) do
        :gen_udp.close(socket)
        :ok
      end

    emit_result_telemetry(result, start_time, metadata)
    result
  end

  @doc """
  Send a broadcast UDP packet and wait for a single response.

  Opens a socket with broadcast enabled, sends the packet, waits for a response
  up to the timeout, and closes the socket. Useful for protocols like DHCPv4
  that send to broadcast addresses and expect a single response.

  ## Parameters

  - `broadcast_addr` - Broadcast IP address (e.g., `{255, 255, 255, 255}`)
  - `dest_port` - Destination port number
  - `packet` - Binary data to send
  - `timeout` - Timeout in milliseconds to wait for response
  - `opts` - Optional keyword list:
    - `:bind_port` - Port to bind the socket to (default: 0 for ephemeral)
    - `:source` - Source IP address to bind
    - `:interface` - Network interface name

  ## Returns

  - `{:ok, response}` - Response binary data received
  - `{:error, :timeout}` - No response within timeout
  - `{:error, reason}` - POSIX error

  ## Examples

      # DHCPv4 discover on client port 68
      iex> Abyss.Client.broadcast_send_recv({255, 255, 255, 255}, 67, dhcp_packet, 5000,
      ...>   bind_port: 68)
      {:ok, <<...response...>>}

      # Fallback to ephemeral port
      iex> Abyss.Client.broadcast_send_recv({255, 255, 255, 255}, 67, dhcp_packet, 5000)
      {:ok, <<...response...>>}
  """
  @spec broadcast_send_recv(
          broadcast_addr(),
          port_number(),
          packet(),
          timeout :: non_neg_integer(),
          opts()
        ) ::
          {:ok, binary()} | {:error, reason() | :timeout}
  def broadcast_send_recv(broadcast_addr, dest_port, packet, timeout, opts \\ []) do
    bind_port = Keyword.get(opts, :bind_port, 0)

    metadata = %{
      host: broadcast_addr,
      port: dest_port,
      size: byte_size(packet),
      type: :broadcast_send_recv,
      timeout: timeout
    }

    start_time = System.monotonic_time()
    :telemetry.execute([:abyss, :client, :send_recv, :start], %{}, metadata)

    socket_opts = [:binary, active: false, broadcast: true, reuseaddr: true]

    result =
      case :gen_udp.open(bind_port, socket_opts) do
        {:ok, socket} ->
          try do
            :gen_udp.send(socket, broadcast_addr, dest_port, packet)

            case :gen_udp.recv(socket, 0, timeout) do
              {:ok, {_ip, _port, response}} -> {:ok, response}
              {:error, _reason} = error -> error
            end
          after
            :gen_udp.close(socket)
          end

        {:error, _reason} = error ->
          error
      end

    emit_send_recv_telemetry(result, start_time, metadata)
    result
  end

  @doc """
  Send a multicast UDP query and collect responses with source address info.

  Opens an ephemeral socket, sends the packet to a multicast address, and
  collects responses until timeout. Returns responses with source IP and port
  for each responder.

  ## Parameters

  - `multicast_addr` - Multicast IP address (e.g., `{224, 0, 0, 251}`)
  - `port` - Destination port number (e.g., 5353)
  - `packet` - Binary data to send
  - `timeout` - Timeout in milliseconds to collect responses
  - `opts` - Optional keyword list:
    - `:ttl` - Multicast TTL (default: 255)

  ## Returns

  - `{:ok, [{address, port, binary}]}` - List of responses with source info
  - `{:error, reason}` - POSIX error

  ## Examples

      # mDNS query
      iex> Abyss.Client.multicast_query({224, 0, 0, 251}, 5353, mdns_packet, 3000)
      {:ok, [{{192, 168, 1, 5}, 5353, <<...response...>>}]}
  """
  @spec multicast_query(
          broadcast_addr(),
          port_number(),
          packet(),
          timeout :: non_neg_integer(),
          opts()
        ) ::
          {:ok, [{:inet.ip_address(), :inet.port_number(), binary()}]} | {:error, reason()}
  def multicast_query(multicast_addr, port, packet, timeout, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, 255)

    metadata = %{
      host: multicast_addr,
      port: port,
      size: byte_size(packet),
      type: :multicast_query,
      timeout: timeout
    }

    start_time = System.monotonic_time()
    :telemetry.execute([:abyss, :client, :send_recv, :start], %{}, metadata)

    socket_opts = [
      :binary,
      active: false,
      multicast_ttl: ttl,
      multicast_loop: true,
      reuseaddr: true
    ]

    result =
      case :gen_udp.open(0, socket_opts) do
        {:ok, socket} ->
          try do
            :gen_udp.send(socket, multicast_addr, port, packet)
            sources = collect_sources(socket, timeout, [])
            {:ok, sources}
          after
            :gen_udp.close(socket)
          end

        {:error, _reason} = error ->
          error
      end

    emit_multicast_telemetry(result, start_time, metadata)
    result
  end

  # Build socket options from caller opts
  @spec build_socket_opts(opts(), boolean()) :: [:gen_udp.option()]
  defp build_socket_opts(opts, broadcast) do
    build_socket_opts(opts, broadcast, nil)
  end

  @spec build_socket_opts(opts(), boolean(), broadcast_addr() | nil) :: [:gen_udp.option()]
  defp build_socket_opts(opts, broadcast, dest_addr) do
    base_opts = [:binary]

    base_opts
    |> maybe_add_broadcast(broadcast)
    |> maybe_add_multicast_opts(dest_addr, opts)
    |> maybe_add_source(opts[:source])
    |> maybe_add_interface(opts[:interface], opts[:source])
  end

  defp maybe_add_broadcast(socket_opts, true), do: [{:broadcast, true} | socket_opts]
  defp maybe_add_broadcast(socket_opts, false), do: socket_opts

  defp maybe_add_multicast_opts(socket_opts, nil, _opts), do: socket_opts

  defp maybe_add_multicast_opts(socket_opts, dest_addr, opts) do
    if multicast_address?(dest_addr) do
      ttl = Keyword.get(opts, :ttl, 1)
      source = opts[:source]

      socket_opts
      |> add_if_present({:multicast_ttl, ttl})
      |> maybe_add_multicast_if(source)
      |> add_if_present({:multicast_loop, false})
    else
      socket_opts
    end
  end

  defp maybe_add_multicast_if(socket_opts, nil), do: socket_opts
  defp maybe_add_multicast_if(socket_opts, source), do: [{:multicast_if, source} | socket_opts]

  defp maybe_add_source(socket_opts, nil), do: socket_opts
  defp maybe_add_source(socket_opts, source), do: [{:ip, source} | socket_opts]

  # Interface binding - Linux uses :bind_to_device, fallback to IP resolution
  defp maybe_add_interface(socket_opts, nil, _source), do: socket_opts

  defp maybe_add_interface(socket_opts, interface, source) when is_binary(interface) do
    # If source is already provided, interface binding may be redundant
    # but we still try to bind to device for proper routing
    case try_bind_to_device(interface, socket_opts) do
      {:ok, updated_opts} ->
        updated_opts

      {:error, _reason} ->
        # Fallback: resolve interface to IP if no source provided
        if is_nil(source) do
          case resolve_interface_ip(interface) do
            {:ok, ip} -> [{:ip, ip} | socket_opts]
            {:error, _} -> socket_opts
          end
        else
          socket_opts
        end
    end
  end

  # Try to use bind_to_device (Linux-specific, requires CAP_NET_RAW or root)
  # Returns {:ok, updated_opts} or {:error, reason}
  defp try_bind_to_device(interface, socket_opts) do
    # :bind_to_device requires charlist on some Erlang versions
    device = String.to_charlist(interface)

    # First check if the interface exists before attempting bind_to_device
    # This avoids the :badarg error from :gen_udp.open
    case interface_exists?(interface) do
      true ->
        # Test if bind_to_device is supported by attempting a dry-run
        do_try_bind_to_device(device, socket_opts)

      false ->
        {:error, :enodev}
    end
  end

  defp do_try_bind_to_device(device, socket_opts) do
    # Wrap in try/catch to handle all possible errors from gen_udp.open
    try do
      case :gen_udp.open(0, [:binary, {:bind_to_device, device}]) do
        {:ok, test_socket} ->
          :gen_udp.close(test_socket)
          {:ok, [{:bind_to_device, device} | socket_opts]}

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :error, :badarg -> {:error, :einval}
      :exit, reason -> {:error, reason}
    end
  end

  defp interface_exists?(interface) do
    case :inet.getifaddrs() do
      {:ok, addrs} ->
        interface_charlist = String.to_charlist(interface)
        List.keyfind(addrs, interface_charlist, 0) != nil

      {:error, _} ->
        false
    end
  end

  @doc """
  Resolve a network interface name to its primary IPv4 address.

  ## Parameters

  - `interface` - Network interface name (e.g., "eth0", "lo")

  ## Returns

  - `{:ok, ip_address}` - IPv4 address tuple
  - `{:error, :enodev}` - Interface not found or has no IPv4 address

  ## Examples

      iex> Abyss.Client.resolve_interface_ip("lo")
      {:ok, {127, 0, 0, 1}}
  """
  @spec resolve_interface_ip(String.t()) :: {:ok, :inet.ip4_address()} | {:error, :enodev}
  def resolve_interface_ip(interface) do
    case :inet.getifaddrs() do
      {:ok, addrs} ->
        interface_charlist = String.to_charlist(interface)

        # inet.getifaddrs returns a list of tuples like [{~c"lo", [...]}, {~c"eth0", [...]}]
        # Use List.keyfind instead of Keyword.get since keys are charlists, not atoms
        case List.keyfind(addrs, interface_charlist, 0) do
          nil ->
            {:error, :enodev}

          {_name, opts} ->
            # Get IPv4 address (4-tuple), skip IPv6 (8-tuple)
            case find_ipv4_addr(opts) do
              nil -> {:error, :enodev}
              addr -> {:ok, addr}
            end
        end

      {:error, _reason} ->
        {:error, :enodev}
    end
  end

  defp find_ipv4_addr(opts) do
    # opts is a keyword list with atom keys like :addr, :netmask, etc.
    opts
    |> Keyword.get_values(:addr)
    |> Enum.find(fn
      {_, _, _, _} -> true
      _ -> false
    end)
  end

  # Check if address is in multicast range (224.0.0.0/4)
  defp multicast_address?({a, _, _, _}) when a >= 224 and a <= 239, do: true
  defp multicast_address?(_), do: false

  defp add_if_present(socket_opts, opt), do: [opt | socket_opts]

  # Emit success or error telemetry
  defp emit_result_telemetry(:ok, start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:abyss, :client, :send, :stop],
      %{duration: duration},
      metadata
    )
  end

  defp emit_result_telemetry({:error, reason}, start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:abyss, :client, :send, :exception],
      %{duration: duration},
      Map.put(metadata, :reason, reason)
    )
  end

  # Emit telemetry for send_recv operations (single response)
  defp emit_send_recv_telemetry({:ok, response}, start_time, metadata) when is_binary(response) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:abyss, :client, :send_recv, :stop],
      %{duration: duration, response_size: byte_size(response)},
      metadata
    )
  end

  defp emit_send_recv_telemetry({:error, reason}, start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:abyss, :client, :send_recv, :exception],
      %{duration: duration},
      Map.put(metadata, :reason, reason)
    )
  end

  # Emit telemetry for subscribe operations (multiple packets)
  defp emit_subscribe_telemetry({:ok, packets}, start_time, metadata) when is_list(packets) do
    duration = System.monotonic_time() - start_time
    total_size = Enum.sum_by(packets, &byte_size/1)

    :telemetry.execute(
      [:abyss, :client, :subscribe, :stop],
      %{duration: duration, packet_count: length(packets), total_size: total_size},
      metadata
    )
  end

  defp emit_subscribe_telemetry({:error, reason}, start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:abyss, :client, :subscribe, :exception],
      %{duration: duration},
      Map.put(metadata, :reason, reason)
    )
  end

  # Collect multicast responses with source address info until timeout
  defp collect_sources(socket, timeout, acc) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_sources(socket, deadline, acc)
  end

  defp do_collect_sources(socket, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      case :gen_udp.recv(socket, 0, remaining) do
        {:ok, {addr, port, data}} ->
          do_collect_sources(socket, deadline, [{addr, port, data} | acc])

        {:error, :timeout} ->
          Enum.reverse(acc)

        {:error, _reason} ->
          Enum.reverse(acc)
      end
    end
  end

  # Emit telemetry for multicast_query operations
  defp emit_multicast_telemetry({:ok, sources}, start_time, metadata) when is_list(sources) do
    duration = System.monotonic_time() - start_time
    total_size = Enum.sum_by(sources, fn {_, _, data} -> byte_size(data) end)

    :telemetry.execute(
      [:abyss, :client, :send_recv, :stop],
      %{duration: duration, response_count: length(sources), total_size: total_size},
      metadata
    )
  end

  defp emit_multicast_telemetry({:error, reason}, start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:abyss, :client, :send_recv, :exception],
      %{duration: duration},
      Map.put(metadata, :reason, reason)
    )
  end
end
