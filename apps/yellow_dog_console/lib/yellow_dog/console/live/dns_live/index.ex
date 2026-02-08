defmodule YellowDog.Console.DnsLive.Index do
  @moduledoc """
  DNS Overview page showing service status, summary statistics, and cache metrics.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper, only: [safe_call: 3]

  alias YellowDog.Dns.View

  @max_cache_entries 10_000

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

  defp get_dns_status do
    safe_call(YellowDog.Dns, fn -> YellowDog.Dns.status() end, %{
      running: false,
      info: "DNS service not running"
    })
  end

  defp get_dns_stats do
    try do
      views = YellowDog.Dns.ViewManager.list_views()

      view_stats =
        Enum.map(views, fn {view_name, pid, priority} ->
          stats = View.stats(pid)

          %{
            name: view_name,
            priority: priority,
            recursion_enabled: Map.get(stats, :recursion_enabled, false),
            zone_count: length(Map.get(stats, :zones, [])),
            query_count: Map.get(stats, :query_count, 0),
            hit_count: Map.get(stats, :hit_count, 0),
            miss_count: Map.get(stats, :miss_count, 0),
            cache_size: Map.get(stats, :cache_size, 0)
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
    catch
      _, _ ->
        %{
          view_count: 0,
          total_zones: 0,
          total_queries: 0,
          total_hits: 0,
          total_misses: 0,
          total_cache: 0,
          views: []
        }
    end
  end

  defp get_cache_stats do
    try do
      zones = YellowDog.Dns.ZoneController.list_zones()

      cache_stats =
        for({:cache, _name, pid} <- zones, do: YellowDog.Dns.Zone.Cache.stats(pid))
        |> Enum.reduce(
          %{current_size: 0, hit_count: 0, miss_count: 0, insert_count: 0, eviction_count: 0},
          fn stat, acc ->
            %{
              current_size: acc.current_size + Map.get(stat, :current_size, 0),
              hit_count: acc.hit_count + Map.get(stat, :hit_count, 0),
              miss_count: acc.miss_count + Map.get(stat, :miss_count, 0),
              insert_count: acc.insert_count + Map.get(stat, :insert_count, 0),
              eviction_count: acc.eviction_count + Map.get(stat, :eviction_count, 0)
            }
          end
        )

      %{
        total_entries: cache_stats.current_size,
        hit_count: cache_stats.hit_count,
        miss_count: cache_stats.miss_count,
        insert_count: cache_stats.insert_count,
        eviction_count: cache_stats.eviction_count,
        max_entries: @max_cache_entries
      }
    catch
      _, _ ->
        %{
          total_entries: 0,
          hit_count: 0,
          miss_count: 0,
          insert_count: 0,
          eviction_count: 0,
          max_entries: @max_cache_entries
        }
    end
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
