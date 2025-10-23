defmodule Abyss.Transport.UDP do
  @moduledoc """
  Defines a `Abyss.Transport` implementation based on clear UDP sockets
  as provided by Erlang's `:gen_udp` module. For the most part, users of Abyss
  will only ever need to deal with this module via `transport_options`
  passed to `Abyss` at startup time. A complete list of such options
  is defined via the `t::gen_udp.open_option/0` type. This list can be somewhat
  difficult to decipher; by far the most common value to pass to this transport
  is the following:

  * `ip`:  The IP to listen on. Can be specified as:
    * `{1, 2, 3, 4}` for IPv4 addresses
    * `{1, 2, 3, 4, 5, 6, 7, 8}` for IPv6 addresses
    * `:loopback` for local loopback
    * `:any` for all interfaces (i.e.: `0.0.0.0`)
    * `{:local, "/path/to/socket"}` for a Unix domain socket. If this option is used,
      the `port` option *must* be set to `0`

  Unless overridden, this module uses the following default options:

  ```elixir
  reuseaddr: true
  ```

  The following options are required for the proper operation of Abyss
  and cannot be overridden:

  ```elixir
  mode: :binary,
  active: false
  ```
  """
  @behaviour Abyss.Transport

  @hardcoded_options [mode: :binary, reuseaddr: true, reuseport: true]

  @impl Abyss.Transport
  @spec listen(:inet.port_number(), [:inet.inet_backend() | :gen_udp.open_option()]) ::
          Abyss.Transport.on_listen()
  def listen(port, user_options) do
    default_options = []

    # We can't use Keyword functions here because :gen_udp accepts non-keyword style options
    resolved_options =
      Enum.uniq_by(
        @hardcoded_options ++ user_options ++ default_options,
        fn
          {key, _} when is_atom(key) -> key
          key when is_atom(key) -> key
        end
      )

    :gen_udp.open(port, resolved_options)
  end

  @spec open(:inet.port_number(), [:inet.inet_backend() | :gen_udp.open_option()]) ::
          Abyss.Transport.on_open()
  def open(port, user_options) do
    default_options = []

    # We can't use Keyword functions here because :gen_udp accepts non-keyword style options
    resolved_options =
      Enum.uniq_by(
        @hardcoded_options ++ user_options ++ default_options,
        fn
          {key, _} when is_atom(key) -> key
          key when is_atom(key) -> key
        end
      )

    :gen_udp.open(port, resolved_options)
  end

  @impl Abyss.Transport
  @spec controlling_process(Abyss.Transport.socket(), pid()) ::
          Abyss.Transport.on_controlling_process()
  def controlling_process(socket, pid) do
    :gen_udp.controlling_process(socket, pid)
  end

  @impl Abyss.Transport
  @spec recv(Abyss.Transport.socket(), non_neg_integer(), timeout()) :: Abyss.Transport.on_recv()
  defdelegate recv(socket, length, timeout), to: :gen_udp

  @spec recv(Abyss.Transport.socket(), non_neg_integer()) :: Abyss.Transport.on_recv()
  defdelegate recv(socket, length), to: :gen_udp

  @impl Abyss.Transport
  @spec send(Abyss.Transport.socket(), iodata()) :: Abyss.Transport.on_send()
  defdelegate send(socket, data), to: :gen_udp
  defdelegate send(socket, dest, data), to: :gen_udp
  defdelegate send(socket, ip, port, data), to: :gen_udp
  defdelegate send(socket, ip, port, anc_data, data), to: :gen_udp

  @impl Abyss.Transport
  @spec getopts(Abyss.Transport.socket(), Abyss.Transport.socket_get_options()) ::
          Abyss.Transport.on_getopts()
  defdelegate getopts(socket, options), to: :inet

  @impl Abyss.Transport
  @spec setopts(Abyss.Transport.socket(), Abyss.Transport.socket_set_options()) ::
          Abyss.Transport.on_setopts()
  defdelegate setopts(socket, options), to: :inet

  @impl Abyss.Transport
  @spec close(Abyss.Transport.socket() | Abyss.Transport.listener_socket()) :: :ok
  defdelegate close(socket), to: :gen_udp

  @impl Abyss.Transport
  @spec sockname(Abyss.Transport.socket() | Abyss.Transport.listener_socket()) ::
          Abyss.Transport.on_sockname()
  defdelegate sockname(socket), to: :inet

  @impl Abyss.Transport
  @spec peername(Abyss.Transport.socket()) :: Abyss.Transport.on_peername()
  defdelegate peername(socket), to: :inet

  @impl Abyss.Transport
  @spec getstat(Abyss.Transport.socket()) :: Abyss.Transport.socket_stats()
  defdelegate getstat(socket), to: :inet

  @spec send_recv(
          {Abyss.Transport.address(), :inet.port_number()},
          iodata(),
          timeout()
        ) :: Abyss.Transport.on_recv()
  def send_recv({ip, port}, data, timeout \\ 5000) do
    case open(0, mode: :binary, active: false) do
      {:ok, socket} ->
        :ok = send(socket, ip, port, data)
        recv(socket, 0, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
