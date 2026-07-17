defmodule YellowDog.ServerDnsControlFake do
  @moduledoc false

  use Agent

  @defaults %{
    views: [],
    view_stats: %{views: %{}},
    zones: {:ok, []},
    records: %{},
    zone_metadata: %{},
    record_state: %{},
    serial_advances: 0,
    responses: %{},
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

  def snapshot, do: Agent.get(__MODULE__, &Map.drop(&1, [:calls]))

  def operation(name, call, default) do
    Agent.get_and_update(__MODULE__, fn state ->
      {response, responses} = pop_response(state.responses, name)
      {result, next_state} = if response == :default, do: default.(state), else: {response, state}
      {result, %{next_state | responses: responses, calls: [call | next_state.calls]}}
    end)
    |> run()
  end

  defp pop_response(responses, name) do
    case Map.get(responses, name, []) do
      [response | rest] -> {response, Map.put(responses, name, rest)}
      _ -> {:default, responses}
    end
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
    YellowDog.ServerDnsControlFake.operation(
      :list_records,
      {:zone_store, :list_records, [view_name, zone_name]},
      fn state -> {{:ok, records_for(state, view_name, zone_name)}, state} end
    )
  end

  def get_zone(view_name, zone_name) do
    YellowDog.ServerDnsControlFake.operation(
      :get_zone,
      {:zone_store, :get_zone, [view_name, zone_name]},
      fn state ->
        result = Map.get(state.zone_metadata, {view_name, zone_name}, {:error, :not_found})
        {{:ok, result} |> unwrap_zone_result(), state}
      end
    )
  end

  defp unwrap_zone_result({:ok, {:error, :not_found}}), do: {:error, :not_found}
  defp unwrap_zone_result({:ok, zone}), do: {:ok, zone}

  def create_zone(view_name, zone_name, soa, opts) do
    YellowDog.ServerDnsControlFake.operation(
      :create_zone,
      {:zone_store, :create_zone, [view_name, zone_name, soa, opts]},
      fn state ->
        zone = %{
          view_name: view_name,
          origin: zone_name,
          zone_type: :auth,
          soa: soa,
          default_ttl: Keyword.get(opts, :default_ttl, 3600),
          authoritative: Keyword.get(opts, :authoritative, true),
          allow_dynamic_update: Keyword.get(opts, :allow_dynamic_update, false),
          serial_strategy: Keyword.get(opts, :serial_strategy, :date_serial),
          cloud_mirror: Keyword.get(opts, :cloud_mirror)
        }

        {:ok, put_in(state, [:zone_metadata, {view_name, zone_name}], zone)}
      end
    )
  end

  def update_zone(view_name, zone_name, attrs) do
    YellowDog.ServerDnsControlFake.operation(
      :update_zone,
      {:zone_store, :update_zone, [view_name, zone_name, attrs]},
      fn state ->
        key = {view_name, zone_name}

        case Map.fetch(state.zone_metadata, key) do
          {:ok, zone} -> {:ok, put_in(state, [:zone_metadata, key], Map.merge(zone, attrs))}
          :error -> {{:error, :not_found}, state}
        end
      end
    )
  end

  def delete_zone(view_name, zone_name) do
    YellowDog.ServerDnsControlFake.operation(
      :delete_zone,
      {:zone_store, :delete_zone, [view_name, zone_name]},
      fn state ->
        {:ok,
         state
         |> update_in([:zone_metadata], &Map.delete(&1, {view_name, zone_name}))
         |> update_in([:record_state], fn records ->
           records
           |> Enum.reject(fn {{stored_view, stored_zone}, _records} ->
             stored_view == view_name and stored_zone == zone_name
           end)
           |> Map.new()
         end)}
      end
    )
  end

  def default_soa(zone_name) do
    YellowDog.ServerDnsControlFake.operation(
      :default_soa,
      {:zone_store, :default_soa, [zone_name]},
      fn state -> {%{mname: "ns1.#{zone_name}", rname: "hostmaster.#{zone_name}"}, state} end
    )
  end

  def get_rrset(view_name, zone_name, owner, type) do
    YellowDog.ServerDnsControlFake.operation(
      :get_rrset,
      {:zone_store, :get_rrset, [view_name, zone_name, owner, type]},
      fn state ->
        records = records_for(state, view_name, zone_name)

        result =
          case Enum.filter(records, &(&1.owner == owner and &1.type == type)) do
            [record] -> {:ok, record}
            [] -> {:error, :not_found}
          end

        {result, state}
      end
    )
  end

  def put_rrset(view_name, zone_name, owner, type, rrset) do
    YellowDog.ServerDnsControlFake.operation(
      :put_rrset,
      {:zone_store, :put_rrset, [view_name, zone_name, owner, type, rrset]},
      fn state ->
        records = records_for(state, view_name, zone_name)
        record = %{owner: owner, type: type, rrset: rrset}
        updated = [record | Enum.reject(records, &(&1.owner == owner and &1.type == type))]

        next_state =
          state
          |> put_in([:record_state, {view_name, zone_name}], updated)
          |> Map.update!(:serial_advances, &(&1 + 1))

        {:ok, next_state}
      end
    )
  end

  def delete_rrset(view_name, zone_name, owner, type) do
    YellowDog.ServerDnsControlFake.operation(
      :delete_rrset,
      {:zone_store, :delete_rrset, [view_name, zone_name, owner, type]},
      fn state ->
        updated =
          state
          |> records_for(view_name, zone_name)
          |> Enum.reject(&(&1.owner == owner and &1.type == type))

        next_state =
          state
          |> put_in([:record_state, {view_name, zone_name}], updated)
          |> Map.update!(:serial_advances, &(&1 + 1))

        {:ok, next_state}
      end
    )
  end

  defp records_for(state, view_name, zone_name) do
    Map.get_lazy(state.record_state, {view_name, zone_name}, fn ->
      case state.records do
        records when is_map(records) ->
          case Map.get(records, {view_name, zone_name}, {:ok, []}) do
            {:ok, entries} -> entries
            _ -> []
          end

        _ ->
          []
      end
    end)
  end
end

defmodule YellowDog.ServerDnsControlFake.RealStoreFailingPut do
  @moduledoc false

  defdelegate get_zone(view_name, zone_name), to: YellowDog.Store.Zone
  defdelegate get_rrset(view_name, zone_name, owner, type), to: YellowDog.Store.Zone

  def put_rrset(view_name, zone_name, owner, type, rrset) do
    YellowDog.ServerDnsControlFake.operation(
      :real_store_put_rrset,
      {:zone_store, :put_rrset, [view_name, zone_name, owner, type, rrset]},
      fn state -> {{:error, :store_failed}, state} end
    )
  end

  def delete_rrset(view_name, zone_name, owner, type) do
    YellowDog.ServerDnsControlFake.operation(
      :real_store_delete_rrset,
      {:zone_store, :delete_rrset, [view_name, zone_name, owner, type]},
      fn state ->
        {YellowDog.Store.Zone.delete_rrset(view_name, zone_name, owner, type), state}
      end
    )
  end
end

defmodule YellowDog.ServerDnsControlFake.ZoneController do
  @moduledoc false

  def start_zone(zone_type, zone_name, config) do
    YellowDog.ServerDnsControlFake.operation(
      :start_zone,
      {:zone_controller, :start_zone, [zone_type, zone_name, config]},
      fn state -> {{:ok, self()}, state} end
    )
  end

  def reload_zone(view_name, zone_type, zone_name, config) do
    YellowDog.ServerDnsControlFake.operation(
      :reload_zone,
      {:zone_controller, :reload_zone, [view_name, zone_type, zone_name, config]},
      fn state -> {:ok, state} end
    )
  end

  def stop_zone(view_name, zone_type, zone_name) do
    YellowDog.ServerDnsControlFake.operation(
      :stop_zone,
      {:zone_controller, :stop_zone, [view_name, zone_type, zone_name]},
      fn state -> {:ok, state} end
    )
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

  def get_config(provider_id) do
    YellowDog.ServerDnsControlFake.operation(
      :get_provider,
      {:provider_store, :get_config, [provider_id]},
      fn state ->
        result =
          case state.providers do
            {:ok, providers} when is_list(providers) ->
              case Enum.find(providers, &(Map.get(&1, :name) == provider_id)) do
                nil -> {:error, :not_found}
                provider -> {:ok, provider}
              end

            _ ->
              {:error, :not_found}
          end

        {result, state}
      end
    )
  end
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
