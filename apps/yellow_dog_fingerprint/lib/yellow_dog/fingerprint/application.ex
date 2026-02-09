defmodule YellowDog.Fingerprint.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {YellowDog.Fingerprint.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: YellowDog.Fingerprint.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
