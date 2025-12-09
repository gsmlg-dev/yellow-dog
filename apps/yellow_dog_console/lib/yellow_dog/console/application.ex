defmodule YellowDog.Console.Application do
  @moduledoc """
  The YellowDog Console Application.

  Starts the Phoenix web console for managing and monitoring YellowDog services.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # PubSub for real-time updates
      {Phoenix.PubSub, name: YellowDog.Console.PubSub},
      # Telemetry supervisor for metrics
      YellowDog.Console.Telemetry,
      # Configuration version tracking for settings optimistic locking
      YellowDog.Console.Settings.ConfigurationVersion,
      # Phoenix Endpoint
      YellowDog.Console.Endpoint
    ]

    opts = [strategy: :one_for_one, name: YellowDog.Console.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    YellowDog.Console.Endpoint.config_change(changed, removed)
    :ok
  end
end
