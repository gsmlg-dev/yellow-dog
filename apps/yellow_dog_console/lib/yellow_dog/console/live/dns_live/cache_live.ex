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
      stats = YellowDog.Dns.Query.Cache.Manager.stats()

      # Convert struct to map and add max_entries/max_memory_bytes for UI
      stats
      |> Map.from_struct()
      |> Map.put(:max_entries, @max_cache_entries)
      |> Map.put(:max_memory_bytes, @max_cache_memory_bytes)
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
