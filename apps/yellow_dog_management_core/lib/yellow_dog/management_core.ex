defmodule YellowDog.ManagementCore do
  @moduledoc """
  Public facade for YellowDog management state.

  Concrete server and Netman contexts persist their state without changing the
  console-facing API.
  """

  alias YellowDog.Management.EventStore
  alias YellowDog.Management.Netmans
  alias YellowDog.Management.Profiles
  alias YellowDog.Management.Servers

  @doc "Lists registered managed server instances."
  def list_servers, do: Servers.list()

  @doc "Fetches a registered managed server by id."
  def get_server(id), do: Servers.get(id)

  @doc "Registers or replaces a managed server record."
  def register_server(attrs), do: Servers.register(attrs)

  @doc "Updates the status for a registered managed server."
  def update_server_status(id, status), do: Servers.update_status(id, status)

  @doc "Lists registered Netman instances."
  def list_netmans, do: Netmans.list()

  @doc "Fetches a registered Netman instance by id."
  def get_netman(id), do: Netmans.get(id)

  @doc "Registers or replaces a Netman record."
  def register_netman(attrs), do: Netmans.register(attrs)

  @doc "Updates the status for a registered Netman instance."
  def update_netman_status(id, status), do: Netmans.update_status(id, status)

  @doc "Lists concrete server profiles."
  def list_server_profiles, do: Profiles.list_server_profiles()

  @doc "Lists concrete Netman profiles."
  def list_netman_profiles, do: Profiles.list_netman_profiles()

  @doc "Lists management events in deterministic global order."
  def list_events, do: EventStore.list()
end
