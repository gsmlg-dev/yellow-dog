defmodule Abyss.Transport.UDP.Unicast do
  @moduledoc """
  UDP transport implementation for unicast traffic.

  This transport is optimized for standard unicast UDP communication patterns,
  such as DNS queries, DHCP unicast messages, and other point-to-point UDP protocols.

  ## Characteristics

  - Socket configured with `active: false` for passive receive mode
  - Broadcast disabled (`broadcast: false`)
  - Optimized for request/response patterns
  - Multiple listener processes for load distribution
  - Connection pooling support

  ## Usage

  ```elixir
  Abyss.start_link([
    transport_module: Abyss.Transport.UDP.Unicast,
    handler_module: MyUnicastHandler,
    port: 53,
    num_listeners: 50
  ])
  ```

  ## Handler Requirements

  Handlers used with this transport should implement the `Abyss.Handler` behaviour
  and be designed for unicast request/response patterns.

  ## Default Options

  The following default options are set for unicast traffic:
  - `mode: :binary` - Binary mode for data
  - `reuseaddr: true` - Allow address reuse
  - `reuseport: true` - Allow port reuse across listeners
  - `active: false` - Passive receive mode
  - `broadcast: false` - Disable broadcast

  ## See Also

  - `Abyss.Transport.UDP.Broadcast` - For broadcast/multicast traffic
  - `Abyss.Transport.UDP` - Original unified UDP transport (backward compatibility)
  """

  @behaviour Abyss.Transport

  alias Abyss.Transport.UDP.Core

  @hardcoded_options [
    mode: :binary,
    reuseaddr: true,
    reuseport: true,
    active: false,
    broadcast: false
  ]

  @impl Abyss.Transport
  @doc """
  Creates and returns a listener socket for unicast UDP traffic.

  ## Parameters
  - `port` - The UDP port to listen on
  - `user_options` - Additional socket options provided by the user

  ## Returns
  - `{:ok, socket}` - Successfully opened socket
  - `{:error, reason}` - Failed to open socket

  ## Examples

      iex> Abyss.Transport.UDP.Unicast.listen(5353, [ip: {0, 0, 0, 0}])
      {:ok, #Port<0.1234>}
  """
  @spec listen(:inet.port_number(), [:inet.inet_backend() | :gen_udp.open_option()]) ::
          Abyss.Transport.on_listen()
  def listen(port, user_options) do
    default_options = []

    resolved_options = Core.merge_options(@hardcoded_options ++ default_options, user_options)

    Core.open_socket(port, resolved_options)
  end

  @doc """
  Opens a UDP socket for sending unicast traffic.

  This is typically used for creating client sockets.

  ## Parameters
  - `port` - The local UDP port (use 0 for any available port)
  - `user_options` - Additional socket options

  ## Returns
  - `{:ok, socket}` - Successfully opened socket
  - `{:error, reason}` - Failed to open socket
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
  Utility function to send a message and receive a response.

  This is useful for client-side unicast request/response patterns.

  ## Parameters
  - `{ip, port}` - Remote endpoint to send to
  - `data` - Data to send
  - `timeout` - Receive timeout in milliseconds (default: 5000)

  ## Returns
  - `{:ok, recv_data}` - Successfully received response
  - `{:error, reason}` - Failed to send or receive

  ## Examples

      iex> Abyss.Transport.UDP.Unicast.send_recv({{1, 1, 1, 1}, 53}, dns_query, 5000)
      {:ok, {{1, 1, 1, 1}, 53, dns_response}}
  """
  @spec send_recv(
          {Abyss.Transport.address(), :inet.port_number()},
          iodata(),
          timeout()
        ) :: Abyss.Transport.on_recv()
  def send_recv({ip, port}, data, timeout \\ 5000) do
    case open(0, mode: :binary, active: false) do
      {:ok, socket} ->
        try do
          :ok = Core.send(socket, ip, port, data)
          Core.recv(socket, 0, timeout)
        after
          Core.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
