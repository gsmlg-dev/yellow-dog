defmodule YellowDog.Config.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [YellowDog.Config.Manager],
      strategy: :one_for_one,
      name: YellowDog.Config.Supervisor
    )
  end
end
