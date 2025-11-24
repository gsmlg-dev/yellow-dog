defmodule Abyss.Transport.UDP.Broadcast do
  @moduledoc """
  UDP transport implementation for broadcast and multicast traffic.

  This transport is optimized for broadcast and multicast UDP communication patterns,
  such as DHCP broadcasts, mDNS multicast, and other one-to-many UDP protocols.

  ## Characteristics

  - Socket configured with `active: true` for active receive mode
  - Broadcast enabled (`broadcast: true`)
  - Optimized for one-to-many communication patterns
  - Single listener process (broadcast mode requirement)
  - Support for multicast groups via `add_membership` option

  ## Usage

  ### DHCP Broadcast Example

  ```elixir
  Abyss.start_link([
    transport_module: Abyss.Transport.UDP.Broadcast,
    handler_module: MyDHCPHandler,
    port: 67,
    transport_options: [
      ip: {0, 0, 0, 0},
      broadcast: true
    ]
  ])
  ```

  ### mDNS Multicast Example

  ```elixir
  Abyss.start_link([
    transport_module: Abyss.Transport.UDP.Broadcast,
    handler_module: MyMDNSHandler,
    port: 5353,
    transport_options: [
      ip: {0, 0, 0, 0},
      add_membership: {{224, 0, 0, 251}, {0, 0, 0, 0}},
      multicast_if: {0, 0, 0, 0},
      multicast_ttl: 255
    ]
  ])
  ```

  ## Handler Requirements

  Handlers used with this transport should implement the `Abyss.Handler` behaviour
  and be designed for broadcast/multicast patterns. Handlers typically process
  each packet and then terminate (one packet per handler process).

  ## Default Options

  The following default options are set for broadcast traffic:
  - `mode: :binary` - Binary mode for data
  - `reuseaddr: true` - Allow address reuse (essential for multicast)
  - `reuseport: true` - Allow port reuse (essential for multicast)
  - `active: true` - Active receive mode for broadcast
  - `broadcast: true` - Enable broadcast

  ## Multicast Configuration

  To join a multicast group, add these options to `transport_options`:

  ```elixir
  transport_options: [
    ip: {0, 0, 0, 0},  # Listen on all interfaces
    add_membership: {{224, 0, 0, 251}, {0, 0, 0, 0}},  # Join multicast group
    multicast_if: {0, 0, 0, 0},  # Outgoing interface
    multicast_ttl: 255,  # TTL for multicast packets
    multicast_loop: false  # Don't receive own multicast packets
  ]
  ```

  ## See Also

  - `Abyss.Transport.UDP.Unicast` - For unicast traffic
  - `Abyss.Transport.UDP` - Original unified UDP transport (backward compatibility)
  """

  @behaviour Abyss.Transport

  alias Abyss.Transport.UDP.Core

  @hardcoded_options [
    mode: :binary,
    reuseaddr: true,
    reuseport: true,
    active: true,
    broadcast: true
  ]

  @impl Abyss.Transport
  @doc """
  Creates and returns a listener socket for broadcast/multicast UDP traffic.

  ## Parameters
  - `port` - The UDP port to listen on
  - `user_options` - Additional socket options provided by the user

  ## Returns
  - `{:ok, socket}` - Successfully opened socket
  - `{:error, reason}` - Failed to open socket

  ## Examples

      # DHCP broadcast
      iex> Abyss.Transport.UDP.Broadcast.listen(67, [ip: {0, 0, 0, 0}])
      {:ok, #Port<0.1234>}

      # mDNS multicast
      iex> Abyss.Transport.UDP.Broadcast.listen(5353, [
      ...>   ip: {0, 0, 0, 0},
      ...>   add_membership: {{224, 0, 0, 251}, {0, 0, 0, 0}}
      ...> ])
      {:ok, #Port<0.5678>}
  """
  @spec listen(:inet.port_number(), [:inet.inet_backend() | :gen_udp.open_option()]) ::
          Abyss.Transport.on_listen()
  def listen(port, user_options) do
    default_options = []

    resolved_options = Core.merge_options(@hardcoded_options ++ default_options, user_options)

    Core.open_socket(port, resolved_options)
  end

  @doc """
  Opens a UDP socket for sending broadcast/multicast traffic.

  This is typically used for creating client sockets that need to send
  broadcast or multicast messages.

  ## Parameters
  - `port` - The local UDP port (use 0 for any available port)
  - `user_options` - Additional socket options

  ## Returns
  - `{:ok, socket}` - Successfully opened socket
  - `{:error, reason}` - Failed to open socket

  ## Examples

      # Open socket for sending broadcasts
      iex> Abyss.Transport.UDP.Broadcast.open(0, [ip: {0, 0, 0, 0}])
      {:ok, #Port<0.9999>}
  """
  @spec open(:inet.port_number(), [:inet.inet_backend() | :gen_udp.open_option()]) ::
          Abyss.Transport.on_open()
  def open(port, user_options) do
    default_options = []

    resolved_options = Core.merge_options(@hardcoded_options ++ default_options, user_options)

    Core.open_socket(port, resolved_options)
  end

  # Delegate all other transport operations to Core

  @impl Abyss.Transport
  @spec controlling_process(Abyss.Transport.socket(), pid()) ::
          Abyss.Transport.on_controlling_process()
  defdelegate controlling_process(socket, pid), to: Core

  @impl Abyss.Transport
  @spec recv(Abyss.Transport.socket(), non_neg_integer(), timeout()) ::
          Abyss.Transport.on_recv()
  defdelegate recv(socket, length, timeout), to: Core

  @impl Abyss.Transport
  @spec send(Abyss.Transport.socket(), iodata()) :: Abyss.Transport.on_send()
  defdelegate send(socket, data), to: Core
  defdelegate send(socket, dest, data), to: Core
  defdelegate send(socket, ip, port, data), to: Core
  defdelegate send(socket, ip, port, anc_data, data), to: Core

  @impl Abyss.Transport
  @spec getopts(Abyss.Transport.socket(), Abyss.Transport.socket_get_options()) ::
          Abyss.Transport.on_getopts()
  defdelegate getopts(socket, options), to: Core

  @impl Abyss.Transport
  @spec setopts(Abyss.Transport.socket(), Abyss.Transport.socket_set_options()) ::
          Abyss.Transport.on_setopts()
  defdelegate setopts(socket, options), to: Core

  @impl Abyss.Transport
  @spec close(Abyss.Transport.socket() | Abyss.Transport.listener_socket()) :: :ok
  defdelegate close(socket), to: Core

  @impl Abyss.Transport
  @spec sockname(Abyss.Transport.socket() | Abyss.Transport.listener_socket()) ::
          Abyss.Transport.on_sockname()
  defdelegate sockname(socket), to: Core

  @impl Abyss.Transport
  @spec peername(Abyss.Transport.socket()) :: Abyss.Transport.on_peername()
  defdelegate peername(socket), to: Core

  @impl Abyss.Transport
  @spec getstat(Abyss.Transport.socket()) :: Abyss.Transport.socket_stats()
  defdelegate getstat(socket), to: Core

  @doc """
  Utility function to send a broadcast message.

  ## Parameters
  - `socket` - The UDP socket to send from (must be opened with broadcast: true)
  - `ip` - Broadcast IP address (e.g., {255, 255, 255, 255} or multicast address)
  - `port` - Destination port
  - `data` - Data to broadcast

  ## Returns
  - `:ok` - Successfully sent
  - `{:error, reason}` - Failed to send

  ## Examples

      # Send DHCP broadcast
      iex> {:ok, socket} = Abyss.Transport.UDP.Broadcast.open(0, [])
      iex> Abyss.Transport.UDP.Broadcast.send_broadcast(socket, {255, 255, 255, 255}, 67, dhcp_packet)
      :ok

      # Send mDNS multicast
      iex> {:ok, socket} = Abyss.Transport.UDP.Broadcast.open(0, [])
      iex> Abyss.Transport.UDP.Broadcast.send_broadcast(socket, {224, 0, 0, 251}, 5353, mdns_packet)
      :ok
  """
  @spec send_broadcast(
          Abyss.Transport.socket(),
          Abyss.Transport.address(),
          :inet.port_number(),
          iodata()
        ) :: :ok | {:error, term()}
  def send_broadcast(socket, ip, port, data) do
    Core.send(socket, ip, port, data)
  end
end
