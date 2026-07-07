defmodule YellowDog.NetmanAgent do
  @moduledoc """
  Public facade for the local `yellow_dog_netman` management agent skeleton.
  """

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
  def status_snapshot, do: Status.snapshot()
end
