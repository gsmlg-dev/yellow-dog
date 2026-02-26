defmodule YellowDog.Resolved.Application do
  @moduledoc """
  OTP Application for the YellowDog Resolved DNS stub resolver.

  Starts the supervision tree containing config, cache, listener,
  forwarder, and optional discovery/management components.
  """

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:yellow_dog_resolved, :start_services, true) do
      YellowDog.Resolved.Supervisor.start_link([])
    else
      # In test mode, start a bare supervisor — tests start components individually
      Supervisor.start_link([], strategy: :one_for_one, name: YellowDog.Resolved.Supervisor)
    end
  end
end
