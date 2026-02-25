defmodule YellowDog.Resolved.Supervisor do
  @moduledoc """
  Top-level supervisor for the resolved DNS stub resolver.

  Supervision tree:
  - Config (TOML config loader + watcher)
  - Cache (ETS-based DNS cache)
  - Metrics (query counter accumulator)
  - Forwarder (upstream query correlation)
  - Listener (Abyss UDP listener on 127.0.0.1:53)
  - Discovery (EDNS probe + WS management, optional)
  """

  use Supervisor

  @doc "Start the resolved supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = YellowDog.Resolved.Config.load()

    children =
      [
        {YellowDog.Resolved.Config, config},
        {YellowDog.Resolved.Cache, config.cache},
        YellowDog.Resolved.Metrics,
        {YellowDog.Resolved.Forwarder, config},
        listener_child_spec(config)
      ] ++ discovery_children(config)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp listener_child_spec(config) do
    {YellowDog.Resolved.Listener, config}
  end

  defp discovery_children(%{discovery: %{enabled: true}} = config) do
    [{YellowDog.Resolved.Discovery, config}]
  end

  defp discovery_children(_config), do: []
end
