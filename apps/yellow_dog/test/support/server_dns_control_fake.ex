defmodule YellowDog.ServerDnsControlFake do
  @moduledoc false

  use Agent

  @defaults %{
    views: [],
    view_stats: %{views: %{}},
    zones: {:ok, []},
    records: %{},
    acls: [],
    providers: {:ok, []},
    logs: [],
    metrics: %{},
    now: ~U[2026-07-16 00:00:00Z]
  }

  def start_link(_opts) do
    Agent.start_link(fn -> Map.put(@defaults, :calls, []) end, name: __MODULE__)
  end

  def configure(values) when is_map(values) do
    Agent.update(__MODULE__, &Map.merge(&1, values))
  end

  def fetch(key, call) do
    Agent.get_and_update(__MODULE__, fn state ->
      {Map.fetch!(state, key), %{state | calls: [call | state.calls]}}
    end)
    |> run()
  end

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def control_views do
    Agent.get_and_update(__MODULE__, fn state ->
      stats_by_view = get_in(state, [:view_stats, :views]) || %{}

      result =
        case state.views do
          views when is_list(views) ->
            control_views =
              Enum.map(views, fn
                {name, _pid, _priority} ->
                  details = Map.get(stats_by_view, name, %{})

                  %{
                    name: name,
                    match_clients: Map.get(details, :match_clients, []),
                    recursion: Map.get(details, :recursion_enabled, false)
                  }

                view when is_map(view) ->
                  view
              end)

            {:ok, control_views}

          other ->
            other
        end

      {result, %{state | calls: [{:view_manager, :list_control_views, []} | state.calls]}}
    end)
    |> run()
  end

  defp run({:raise, reason}), do: raise(reason)
  defp run({:throw, reason}), do: throw(reason)
  defp run({:exit, reason}), do: exit(reason)
  defp run(value), do: value
end

defmodule YellowDog.ServerDnsControlFake.ZoneStore do
  @moduledoc false

  def list_zones_for_view(view_name) do
    case YellowDog.ServerDnsControlFake.fetch(
           :zones,
           {:zone_store, :list_zones_for_view, [view_name]}
         ) do
      zones when is_map(zones) -> Map.get(zones, view_name, {:ok, []})
      result -> result
    end
  end

  def list_records(view_name, zone_name) do
    case YellowDog.ServerDnsControlFake.fetch(
           :records,
           {:zone_store, :list_records, [view_name, zone_name]}
         ) do
      records when is_map(records) -> Map.get(records, {view_name, zone_name}, {:ok, []})
      result -> result
    end
  end
end

defmodule YellowDog.ServerDnsControlFake.AclRegistry do
  @moduledoc false

  def list_acls,
    do: YellowDog.ServerDnsControlFake.fetch(:acls, {:acl_registry, :list_acls, []})
end

defmodule YellowDog.ServerDnsControlFake.AclCodec do
  @moduledoc false

  @canonical_cidrs %{
    "10.0.0.0/8" => "10.0.0.0/8",
    "10.1.0.0/16" => "10.1.0.0/16",
    "10.1.2.3/8" => "10.0.0.0/8",
    "192.0.2.99/24" => "192.0.2.0/24",
    "203.0.113.0/24" => "203.0.113.0/24",
    "2001:0db8:0000:0000:0000:0000:0000:0001/48" => "2001:db8::/48",
    "2001:0db8:0000:0000:0000:0000:0000:1234/32" => "2001:db8::/32"
  }

  def canonical_cidr(cidr) do
    case Map.fetch(@canonical_cidrs, cidr) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :invalid_cidr}
    end
  end
end

defmodule YellowDog.ServerDnsControlFake.ProviderStore do
  @moduledoc false

  def list_configs,
    do: YellowDog.ServerDnsControlFake.fetch(:providers, {:provider_store, :list_configs, []})
end

defmodule YellowDog.ServerDnsControlFake.QueryLogger do
  @moduledoc false

  def get_recent_logs(opts),
    do: YellowDog.ServerDnsControlFake.fetch(:logs, {:query_logger, :get_recent_logs, [opts]})

  def get_logs_by_view(view_name, opts) do
    logs =
      YellowDog.ServerDnsControlFake.fetch(
        :logs,
        {:query_logger, :get_logs_by_view, [view_name, opts]}
      )

    Enum.take(logs, Keyword.get(opts, :limit, 100))
  end

  def control_snapshot(view_name),
    do:
      YellowDog.ServerDnsControlFake.fetch(:logs, {:query_logger, :control_snapshot, [view_name]})
end

defmodule YellowDog.ServerDnsControlFake.MetricsCollector do
  @moduledoc false

  def get_metrics,
    do: YellowDog.ServerDnsControlFake.fetch(:metrics, {:metrics_collector, :get_metrics, []})
end

defmodule YellowDog.ServerDnsControlFake.ViewManager do
  @moduledoc false

  def list_views,
    do: YellowDog.ServerDnsControlFake.fetch(:views, {:view_manager, :list_views, []})

  def stats,
    do: YellowDog.ServerDnsControlFake.fetch(:view_stats, {:view_manager, :stats, []})

  def list_control_views do
    YellowDog.ServerDnsControlFake.control_views()
  end
end

defmodule YellowDog.ServerDnsControlFake.Clock do
  @moduledoc false

  def utc_now, do: YellowDog.ServerDnsControlFake.fetch(:now, {:clock, :utc_now, []})
end
