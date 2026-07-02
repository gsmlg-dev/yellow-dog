defmodule Abyss.DhcpSocket.Native do
  @moduledoc """
  Production DHCP socket implementation via Rust NIF.

  Loads the `dhcp_socket` Rust crate compiled by Rustler. Provides a
  broadcast-capable UDP socket bound to the interface (`SO_BINDTODEVICE` on
  Linux, `IP_BOUND_IF` on FreeBSD) and raw ARP socket support for Duplicate
  Address Detection (RFC 5227).
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
