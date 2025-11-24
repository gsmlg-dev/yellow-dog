defmodule Abyss.Transport.UDP.Core do
  @moduledoc """
  Core UDP transport functionality shared between Unicast and Broadcast transports.

  This module contains common UDP socket operations that are used by both
  `Abyss.Transport.UDP.Unicast` and `Abyss.Transport.UDP.Broadcast` to avoid
  code duplication.

  ## Shared Operations

  - Socket control and ownership transfer
  - Data receiving and sending
  - Socket option management
  - Socket information retrieval
  - Connection statistics

  This module is not meant to be used directly. Use the specific transport
  modules instead:
  - `Abyss.Transport.UDP.Unicast` for unicast traffic
  - `Abyss.Transport.UDP.Broadcast` for broadcast/multicast traffic
  """

  @doc """
  Transfers ownership of the given socket to the given process.
  """
  @spec controlling_process(Abyss.Transport.socket(), pid()) ::
          Abyss.Transport.on_controlling_process()
  defdelegate controlling_process(socket, pid), to: :gen_udp

  @doc """
  Receives data from a UDP socket.
  """
  @spec recv(Abyss.Transport.socket(), non_neg_integer(), timeout()) ::
          Abyss.Transport.on_recv()
  defdelegate recv(socket, length, timeout), to: :gen_udp

  @spec recv(Abyss.Transport.socket(), non_neg_integer()) :: Abyss.Transport.on_recv()
  defdelegate recv(socket, length), to: :gen_udp

  @doc """
  Sends data on a UDP socket.
  """
  @spec send(Abyss.Transport.socket(), iodata()) :: Abyss.Transport.on_send()
  defdelegate send(socket, data), to: :gen_udp
  defdelegate send(socket, dest, data), to: :gen_udp
  defdelegate send(socket, ip, port, data), to: :gen_udp
  defdelegate send(socket, ip, port, anc_data, data), to: :gen_udp

  @doc """
  Gets socket options.
  """
  @spec getopts(Abyss.Transport.socket(), Abyss.Transport.socket_get_options()) ::
          Abyss.Transport.on_getopts()
  defdelegate getopts(socket, options), to: :inet

  @doc """
  Sets socket options.
  """
  @spec setopts(Abyss.Transport.socket(), Abyss.Transport.socket_set_options()) ::
          Abyss.Transport.on_setopts()
  defdelegate setopts(socket, options), to: :inet

  @doc """
  Closes a UDP socket.
  """
  @spec close(Abyss.Transport.socket() | Abyss.Transport.listener_socket()) :: :ok
  defdelegate close(socket), to: :gen_udp

  @doc """
  Returns information about the local socket endpoint.
  """
  @spec sockname(Abyss.Transport.socket() | Abyss.Transport.listener_socket()) ::
          Abyss.Transport.on_sockname()
  defdelegate sockname(socket), to: :inet

  @doc """
  Returns information about the remote socket endpoint.
  """
  @spec peername(Abyss.Transport.socket()) :: Abyss.Transport.on_peername()
  defdelegate peername(socket), to: :inet

  @doc """
  Returns statistics about the socket connection.
  """
  @spec getstat(Abyss.Transport.socket()) :: Abyss.Transport.socket_stats()
  defdelegate getstat(socket), to: :inet

  @doc """
  Merges user options with default options, ensuring user options take precedence.

  The function handles both keyword-style options (e.g., `{:key, value}`) and
  atom-style options (e.g., `:atom_option`).

  ## Parameters
  - `default_options` - Default options to use as base
  - `user_options` - User-provided options that override defaults

  ## Returns
  - Merged options list with user options taking precedence
  """
  @spec merge_options(keyword(), keyword()) :: keyword()
  def merge_options(default_options, user_options) do
    Enum.uniq_by(
      user_options ++ default_options,
      fn
        {key, _} when is_atom(key) -> key
        key when is_atom(key) -> key
      end
    )
  end

  @doc """
  Opens a UDP socket with the given port and options.

  This is a common helper used by both Unicast and Broadcast transports.
  """
  @spec open_socket(:inet.port_number(), [:inet.inet_backend() | :gen_udp.open_option()]) ::
          {:ok, Abyss.Transport.socket()} | {:error, :system_limit} | {:error, :inet.posix()}
  def open_socket(port, options) do
    :gen_udp.open(port, options)
  end
end
