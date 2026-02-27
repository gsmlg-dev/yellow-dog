defmodule YellowDog.Netman.API.Supervisor do
  @moduledoc """
  Supervisor for the CLI API layer.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {YellowDog.Netman.API.CLI, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
