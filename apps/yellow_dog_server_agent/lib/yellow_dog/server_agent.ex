defmodule YellowDog.ServerAgent do
  @moduledoc """
  Public facade for the local `yellow_dog_server` management agent skeleton.
  """

  alias YellowDog.ServerAgent.Client
  alias YellowDog.ServerAgent.Status
  alias YellowDog.ServerAgent.Supervisor

  @doc "Starts the server agent supervision tree."
  def start_link(opts \\ []), do: Supervisor.start_link(opts)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Returns a safe local status snapshot without contacting management core."
  def status_snapshot(opts \\ []), do: Status.snapshot(opts)

  @doc "Reports whether the configured outbound Client is active."
  def connected?(client \\ Client), do: Client.connected?(client)

  @doc "Returns the bounded local outbound connection state."
  def connection_state(client \\ Client), do: Client.connection_state(client)
end
