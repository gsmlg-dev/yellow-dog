defmodule YellowDog.NetmanAgent do
  @moduledoc """
  Public facade for the local `yellow_dog_netman` management agent skeleton.
  """

  alias YellowDog.NetmanAgent.Client
  alias YellowDog.NetmanAgent.ConfigApplyStore
  alias YellowDog.NetmanAgent.Status
  alias YellowDog.NetmanAgent.Supervisor

  @doc "Starts the Netman agent supervision tree."
  def start_link(opts \\ []), do: Supervisor.start_link(opts)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Returns a local status snapshot without contacting management core."
  def status_snapshot(client \\ Client, config_apply_store \\ ConfigApplyStore),
    do: Status.snapshot(client, config_apply_store)

  @doc "Returns whether the typed management connection is active."
  def connected?(client \\ Client), do: Client.connected?(client)

  @doc "Returns the typed management connection lifecycle state."
  def connection_state(client \\ Client), do: Client.connection_state(client)
end
