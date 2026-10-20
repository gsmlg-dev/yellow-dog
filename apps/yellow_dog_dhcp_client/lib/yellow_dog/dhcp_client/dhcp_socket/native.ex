defmodule YellowDog.DhcpClient.DhcpSocket.Native do
  @moduledoc """
  DHCP client adapter for the optional upstream production socket NIF.

  The Rustler dependency and native crate live in `:abyss_dhcp_socket`;
  core `:abyss` supplies the facade used by this adapter.
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
