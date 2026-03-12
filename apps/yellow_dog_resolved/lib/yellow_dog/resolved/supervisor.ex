defmodule YellowDog.Resolved.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = YellowDog.Resolved.Config.load()

    children = [
      {YellowDog.Resolved.Config, config},
      {YellowDog.Resolved.Counters, []},
      {YellowDog.Resolved.Cache, config.cache},
      {YellowDog.Resolved.Forwarder, config},
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
