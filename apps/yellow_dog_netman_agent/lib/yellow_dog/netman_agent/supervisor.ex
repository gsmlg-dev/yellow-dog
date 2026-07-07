defmodule YellowDog.NetmanAgent.Supervisor do
  @moduledoc false

  use Supervisor

  @behaviour Application

  @impl Application
  def start(_type, args), do: start_link(args)

  @impl Application
  def stop(_state), do: :ok

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    children = [
      {YellowDog.NetmanAgent.Heartbeat, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
