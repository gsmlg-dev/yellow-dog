defmodule YellowDog.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Configuration manager
      {YellowDog.Config, %{}}
    ]

    opts = [strategy: :one_for_one, name: YellowDog.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
