defmodule YellowDog.Console.DnsLive.Index do
  @moduledoc """
  DNS overview page showing status, statistics, and quick actions.
  """
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to DNS updates
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:cache")
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Service")
     |> assign(:status, get_dns_status())
     |> assign(:stats, get_dns_stats())}
  end

  @impl true
  def handle_info({:zone_loaded, _zone_name}, socket) do
    {:noreply,
     socket
     |> assign(:stats, get_dns_stats())
     |> put_flash(:info, "Zone loaded successfully")}
  end

  @impl true
  def handle_info({:zone_updated, _zone_name}, socket) do
    {:noreply, assign(socket, :stats, get_dns_stats())}
  end

  @impl true
  def handle_info({:cache_updated, _entry}, socket) do
    {:noreply, assign(socket, :stats, get_dns_stats())}
  end

  defp get_dns_status do
    try do
      YellowDog.Dns.status()
    rescue
      _ -> %{running: false, info: "DNS service not running"}
    end
  end

  defp get_dns_stats do
    try do
      YellowDog.Dns.stats()
    rescue
      _ ->
        %{
          zones: %{loaded_zones: 0, total_zones: 0, total_records: 0, memory_mb: 0},
          storage: %{total_zones: 0, total_records: 0, memory_bytes: 0, memory_mb: 0},
          service: %{running: false, info: "DNS service not running"}
        }
    end
  end

  defp get_cache_entries(_stats) do
    # Try to get cache stats
    try do
      case YellowDog.Dns.Query.Cache.Manager.stats() do
        %{total_entries: entries} -> entries
        _ -> 0
      end
    rescue
      _ -> 0
    end
  end

  defp format_memory(mb) when is_float(mb), do: "#{:erlang.float_to_binary(mb, decimals: 2)} MB"
  defp format_memory(mb) when is_integer(mb), do: "#{mb} MB"
  defp format_memory(_), do: "0 MB"
end
