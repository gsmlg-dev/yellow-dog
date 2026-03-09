defmodule YellowDog.Resolved.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Mix.env() == :test do
        []
      else
        [{YellowDog.Resolved.Supervisor, []}]
      end

    opts = [strategy: :one_for_one, name: YellowDog.Resolved.App]
    Supervisor.start_link(children, opts)
  end
end
