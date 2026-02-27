defmodule YellowDog.DhcpClient.DhcpSocket.Native do
  @moduledoc """
  Production DHCP socket implementation via Rust NIF.

  Loads the `dhcp_socket` Rust crate compiled by Rustler. Provides a
  broadcast-capable UDP socket bound to the interface (`SO_BINDTODEVICE` on
  Linux, `IP_BOUND_IF` on FreeBSD) and raw ARP socket support for Duplicate
  Address Detection (RFC 5227).

  This module is the production implementation of the `DhcpSocket` behaviour.
  For development and testing, `DhcpSocket.UdpFallback` is used instead.

  ## Fallback

  If the NIF fails to load (e.g., Rust toolchain not available in CI), the
  `DhcpSocket.default_impl/0` falls back to `UdpFallback` automatically.
  """

  use Rustler,
    otp_app: :yellow_dog_dhcp_client,
    crate: "dhcp_socket"

  @behaviour YellowDog.DhcpClient.DhcpSocket

  @impl true
  def open(_interface, _owner), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def send_broadcast(_socket, _packet), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def send_unicast(_socket, _dest_ip, _packet), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def send_arp_probe(_socket, _target_ip), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def close(_socket), do: :erlang.nif_error(:nif_not_loaded)
end
