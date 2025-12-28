defmodule YellowDog.Console.DnsLive.CacheLive do
  @moduledoc """
  DNS cache statistics and management page.
  """
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:cache")
      # Schedule periodic refresh
      :timer.send_interval(5_000, self(), :refresh_stats)
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Cache")
     |> assign(:stats, get_cache_stats())}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    {:noreply, assign(socket, :stats, get_cache_stats())}
  end

  @impl true
  def handle_info({:cache_updated, _entry}, socket) do
    {:noreply, assign(socket, :stats, get_cache_stats())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :stats, get_cache_stats())}
  end

  @max_cache_entries 10_000
  @max_cache_memory_bytes 100 * 1024 * 1024

  defp get_cache_stats do
    try do
      # Get cache stats from ZoneController's cache zones
      zones = YellowDog.Dns.ZoneController.list_zones()

      cache_stats =
        zones
        |> Enum.filter(fn {type, _name, _pid} -> type == :cache end)
        |> Enum.map(fn {:cache, _name, pid} ->
          YellowDog.Dns.Zone.Cache.stats(pid)
        end)
        |> Enum.reduce(
          %{
            current_size: 0,
            hit_count: 0,
            miss_count: 0,
            insert_count: 0,
            eviction_count: 0
          },
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
        expired_count: 0,
        memory_bytes: 0,
        collected_at: System.system_time(:second),
        max_entries: @max_cache_entries,
        max_memory_bytes: @max_cache_memory_bytes
      }
    rescue
      _ ->
        %{
          total_entries: 0,
          hit_count: 0,
          miss_count: 0,
          insert_count: 0,
          eviction_count: 0,
          expired_count: 0,
          memory_bytes: 0,
          collected_at: 0,
          max_entries: @max_cache_entries,
          max_memory_bytes: @max_cache_memory_bytes
        }
    end
  end

  defp calculate_hit_rate(%{hit_count: hits, miss_count: misses}) do
    total = hits + misses

    if total > 0 do
      round(hits / total * 100)
    else
      0
    end
  end

  defp calculate_utilization(current, max) when max > 0 do
    round(current / max * 100)
  end

  defp calculate_utilization(_, _), do: 0

  defp calculate_memory_percentage(memory_bytes) do
    # Assuming 100MB limit for visualization
    max_bytes = 100 * 1024 * 1024
    min(round(memory_bytes / max_bytes * 100), 100)
  end

  defp format_memory(bytes) when is_integer(bytes) do
    mb = bytes / 1024 / 1024

    if mb >= 1 do
      "#{:erlang.float_to_binary(mb, decimals: 2)} MB"
    else
      kb = bytes / 1024
      "#{:erlang.float_to_binary(kb, decimals: 2)} KB"
    end
  end

  defp format_memory(_), do: "0 KB"
end
