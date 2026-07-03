defmodule Abyss.DhcpSocket.Native do
  @moduledoc """
  Production DHCP socket implementation via Rust NIF.

  Loads the `dhcp_socket` Rust crate compiled by Rustler. Provides a
  broadcast-capable UDP socket bound to the interface (`SO_BINDTODEVICE` on
  Linux, `IP_BOUND_IF` on FreeBSD) and raw ARP socket support for Duplicate
  Address Detection (RFC 5227).

  ## Owner messages

  A background poll thread delivers messages to the `owner` pid passed to
  `open/2`:

  - `{:dhcp_rx, binary}` - received DHCP packet (raw UDP payload)
  - `{:arp_rx, binary}` - received ARP frame (full Ethernet frame)
  - `{:dhcp_socket_down, :poll_error | :recv_error | :socket_error}` - the
    poll thread exited abnormally; the socket no longer receives packets and
    the owner should `close/1` it and open a new one
  - `{:arp_socket_down, :recv_error | :socket_error}` - the ARP socket
    failed; DAD probes are unavailable but DHCP reception continues

  No message is sent when the thread exits due to `close/1` or because the
  owner process died.
  """

  use Rustler,
    otp_app: :abyss,
    crate: "dhcp_socket"

  @spec open(String.t(), pid()) :: {:ok, reference()} | {:error, term()}
  def open(_interface, _owner), do: :erlang.nif_error(:nif_not_loaded)

  @spec send_broadcast(reference(), iodata()) :: :ok | {:error, term()}
  def send_broadcast(_socket, _packet), do: :erlang.nif_error(:nif_not_loaded)

  @spec send_unicast(reference(), :inet.ip4_address(), iodata()) :: :ok | {:error, term()}
  def send_unicast(_socket, _dest_ip, _packet), do: :erlang.nif_error(:nif_not_loaded)

  @spec send_arp_probe(reference(), :inet.ip4_address()) :: :ok | {:error, term()}
  def send_arp_probe(_socket, _target_ip), do: :erlang.nif_error(:nif_not_loaded)

  @spec close(reference()) :: :ok
  def close(_socket), do: :erlang.nif_error(:nif_not_loaded)
end
