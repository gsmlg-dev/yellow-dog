defmodule YellowDog.Netman.PolicyEngine do
  @moduledoc """
  Pure-function module that determines connection priority and
  default route selection.

  No GenServer in Phase 1 — all functions are stateless.

  ## Priority Calculation

  effective_priority = base_priority (from profile) + type_default

  Type defaults: ethernet = 100, wifi = 50, vpn = 30, cellular = 20.

  Higher priority → lower route metric → preferred default route.
  """

  @type_defaults %{
    ethernet: 100,
    wifi: 50,
    vpn: 30,
    cellular: 20
  }

  @doc """
  Determines which active connection should provide the default route.

  Returns `{:ok, connection_id}` or `:none`.
  """
  @spec default_route([map()]) :: {:ok, String.t()} | :none
  def default_route([]), do: :none

  def default_route(active_connections) do
    [best | _] =
      Enum.sort_by(active_connections, &{-effective_priority(&1), &1[:profile_id] || &1[:id]})

    {:ok, best[:profile_id] || best[:id]}
  end

  @doc """
  Calculates route metrics for all active connections.

  Lower metric = preferred route. Derived from priority:
  metric = 1000 - effective_priority (clamped to [1, 9999])
  """
  @spec route_metrics([map()]) :: %{String.t() => non_neg_integer()}
  def route_metrics(active_connections) do
    for conn <- active_connections, into: %{} do
      id = conn[:profile_id] || conn[:id]
      priority = effective_priority(conn)
      metric = max(1, min(9999, 1000 - priority))
      {id, metric}
    end
  end

  @doc """
  Produces a sorted DNS server list from all active connections.

  DNS servers from higher-priority connections come first.
  """
  @spec dns_priority([map()]) :: [map()]
  def dns_priority(active_connections) do
    active_connections
    |> Enum.sort_by(&{-effective_priority(&1), &1[:profile_id] || &1[:id]})
    |> Enum.flat_map(fn conn ->
      dns = conn[:dns] || []

      Enum.map(dns, fn server ->
        %{
          server: server,
          interface: conn[:interface],
          priority: effective_priority(conn)
        }
      end)
    end)
  end

  @doc "Calculates effective priority for a connection."
  @spec effective_priority(map()) :: integer()
  def effective_priority(conn) do
    base = conn[:autoconnect_priority] || conn[:priority] || 0
    type = conn[:type] || :ethernet
    type_default = Map.get(@type_defaults, type, 0)
    base + type_default
  end
end
