defmodule YellowDog.Resolved.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    enabled = Application.get_env(:yellow_dog_resolved, :enabled, true)

    if not enabled do
      Supervisor.init([], strategy: :one_for_one)
    else
      init_children()
    end
  end

  defp init_children do
    config = YellowDog.Resolved.Config.load()

    children = [
      {YellowDog.Resolved.Config, config},
      {YellowDog.Resolved.Counters, []},
      {YellowDog.Resolved.QueryLogger, []},
      {YellowDog.Resolved.Cache, config.cache},
      {YellowDog.Resolved.Forwarder, config},
      {YellowDog.Resolved.LinkDns, []},
      {YellowDog.Resolved.RateLimiter, config},
      {YellowDog.Resolved.Listener, config}
    ]

    children =
      if config.discovery.enabled do
        children ++ [{YellowDog.Resolved.Discovery, config}]
      else
        children
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
