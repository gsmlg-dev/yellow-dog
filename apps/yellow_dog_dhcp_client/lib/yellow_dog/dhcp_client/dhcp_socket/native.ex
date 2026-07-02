defmodule YellowDog.DhcpClient.DhcpSocket.Native do
  @moduledoc """
  DHCP client adapter for the Abyss-owned production socket NIF.

  The Rustler dependency and native crate live in `:abyss`; this module keeps
  the DHCP client's swappable `DhcpSocket` behaviour surface stable.
  """

  @behaviour YellowDog.DhcpClient.DhcpSocket

  @impl true
  defdelegate open(interface, owner), to: Abyss.DhcpSocket.Native

  @impl true
  defdelegate send_broadcast(socket, packet), to: Abyss.DhcpSocket.Native

  @impl true
  defdelegate send_unicast(socket, dest_ip, packet), to: Abyss.DhcpSocket.Native

  @impl true
  defdelegate send_arp_probe(socket, target_ip), to: Abyss.DhcpSocket.Native

  @impl true
  defdelegate close(socket), to: Abyss.DhcpSocket.Native
end
