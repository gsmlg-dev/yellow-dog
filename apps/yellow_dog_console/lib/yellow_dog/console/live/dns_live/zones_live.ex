defmodule YellowDog.Console.DnsLive.ZonesLive do
  @moduledoc """
  DNS zones management page showing all loaded zones and their statistics.
  """
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Zones")
     |> assign(:zones, list_zones())
     |> assign(:filter, "")}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :zones, list_zones())}
  end

  @impl true
  def handle_info({:zone_loaded, _zone_name}, socket) do
    {:noreply,
     socket
     |> assign(:zones, list_zones())
     |> put_flash(:info, "Zone reloaded")}
  end

  @impl true
  def handle_info({:zone_updated, _zone_name}, socket) do
    {:noreply, assign(socket, :zones, list_zones())}
  end

  defp list_zones do
    try do
      case YellowDog.Dns.Zone.Manager.list_zones() do
        {:ok, zone_names} ->
          Enum.map(zone_names, fn zone_name ->
            stats =
              case YellowDog.Dns.Zone.Storage.get_zone_stats(zone_name) do
                {:ok, zone_stats} -> zone_stats
                {:error, _} -> %{record_count: 0, memory_bytes: 0}
              end

            %{
              name: zone_name,
              record_count: Map.get(stats, :record_count, 0),
              memory_mb:
                Map.get(stats, :memory_bytes, 0) |> then(&(&1 / 1_024 / 1_024)) |> Float.round(2)
            }
          end)

        {:error, _} ->
          []
      end
    rescue
      _ -> []
    end
  end

  defp filtered_zones(zones, filter) when filter == "" or is_nil(filter), do: zones

  defp filtered_zones(zones, filter) do
    filter_lower = String.downcase(filter)

    Enum.filter(zones, fn zone ->
      zone.name |> String.downcase() |> String.contains?(filter_lower)
    end)
  end

  defp total_records(zones), do: Enum.sum(Enum.map(zones, & &1.record_count))

  defp total_memory(zones) do
    total_mb = Enum.sum(Enum.map(zones, & &1.memory_mb)) |> Float.round(2)
    "#{total_mb} MB"
  end

  defp format_memory(mb) when is_float(mb), do: "#{:erlang.float_to_binary(mb, decimals: 2)} MB"
  defp format_memory(mb) when is_integer(mb), do: "#{mb} MB"
  defp format_memory(_), do: "0 MB"
end
