defmodule YellowDog.Console.DnsLive.Index do
  @moduledoc """
  DNS Overview page showing service status, summary statistics, and cache metrics.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper, only: [safe_call: 3]

  alias YellowDog.Dns.View

  @max_cache_entries 10_000

  @view_stat_defaults %{
    recursion_enabled: false,
    zones: [],
    query_count: 0,
    hit_count: 0,
    miss_count: 0,
    cache_size: 0
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:views")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:cache")
    end

    {:ok,
     assign(socket,
       page_title: "DNS Overview",
       status: get_dns_status(),
       stats: get_dns_stats(),
       cache_stats: get_cache_stats()
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:status, get_dns_status())
     |> assign(:stats, get_dns_stats())
     |> assign(:cache_stats, get_cache_stats())}
  end

  @impl true
  def handle_info({event, _name}, socket) when event in [:view_updated, :zone_updated] do
    {:noreply, assign(socket, :stats, get_dns_stats())}
  end

  @impl true
  def handle_info({:cache_updated, _entry}, socket) do
    {:noreply, assign(socket, :cache_stats, get_cache_stats())}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "dns:views")
    Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "dns:zones")
    Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "dns:cache")
    :ok
  end

  defp get_dns_status do
    safe_call(YellowDog.Dns, fn -> YellowDog.Dns.status() end, %{
      running: false,
      info: "DNS service not running"
    })
  end

  @default_dns_stats %{
    view_count: 0,
    total_zones: 0,
    total_queries: 0,
    total_hits: 0,
    total_misses: 0,
    total_cache: 0,
    views: []
  }

  defp get_dns_stats do
    safe_call(
      YellowDog.Dns,
      fn ->
        views = YellowDog.Dns.ViewManager.list_views()

        view_stats =
          Enum.map(views, fn {view_name, pid, priority} ->
            stats = Map.merge(@view_stat_defaults, View.stats(pid))

            %{
              name: view_name,
              priority: priority,
              recursion_enabled: stats.recursion_enabled,
              zone_count: length(stats.zones),
              query_count: stats.query_count,
              hit_count: stats.hit_count,
              miss_count: stats.miss_count,
              cache_size: stats.cache_size
            }
          end)

        {zones, queries, hits, misses, cache} =
          Enum.reduce(view_stats, {0, 0, 0, 0, 0}, fn s, {z, q, h, m, c} ->
            {z + s.zone_count, q + s.query_count, h + s.hit_count, m + s.miss_count,
             c + s.cache_size}
          end)

        %{
          view_count: length(views),
          total_zones: zones,
          total_queries: queries,
          total_hits: hits,
          total_misses: misses,
          total_cache: cache,
          views: view_stats
        }
      end,
      @default_dns_stats
    )
  end

  @default_cache_stats %{
    total_entries: 0,
    hit_count: 0,
    miss_count: 0,
    insert_count: 0,
    eviction_count: 0,
    max_entries: @max_cache_entries
  }

  @cache_stat_defaults %{
    current_size: 0,
    hit_count: 0,
    miss_count: 0,
    insert_count: 0,
    eviction_count: 0
  }

  defp get_cache_stats do
    safe_call(
      YellowDog.Dns,
      fn ->
        zones = YellowDog.Dns.ZoneController.list_zones()

        cache_stats =
          for({:cache, _name, pid} <- zones, do: YellowDog.Dns.Zone.Cache.stats(pid))
          |> Enum.reduce(@cache_stat_defaults, fn stat, acc ->
            stat = Map.merge(@cache_stat_defaults, stat)

            %{
              current_size: acc.current_size + stat.current_size,
              hit_count: acc.hit_count + stat.hit_count,
              miss_count: acc.miss_count + stat.miss_count,
              insert_count: acc.insert_count + stat.insert_count,
              eviction_count: acc.eviction_count + stat.eviction_count
            }
          end)

        %{
          total_entries: cache_stats.current_size,
          hit_count: cache_stats.hit_count,
          miss_count: cache_stats.miss_count,
          insert_count: cache_stats.insert_count,
          eviction_count: cache_stats.eviction_count,
          max_entries: @max_cache_entries
        }
      end,
      @default_cache_stats
    )
  end

  defp calculate_hit_rate(hits, misses) do
    total = hits + misses

    if total > 0 do
      round(hits / total * 100)
    else
      0
    end
  end

  defp cache_hit_rate(%{hit_count: hits, miss_count: misses}) do
    calculate_hit_rate(hits, misses)
  end

  defp cache_utilization(current, max) when max > 0 do
    round(current / max * 100)
  end

  defp cache_utilization(_, _), do: 0
end
