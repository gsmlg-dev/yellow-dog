defmodule YellowDog.ServerAgent.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    children = [
      {YellowDog.ServerAgent.Heartbeat, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
