defmodule YellowDog.Console.MdnsLive.Index do
  @moduledoc """
  mDNS overview page showing status, statistics, and quick actions.
  """
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to service updates
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:services")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:monitor")
    end

    {:ok,
     socket
     |> assign(:page_title, "mDNS Service")
     |> assign(:status, get_mdns_status())
     |> assign(:stats, get_mdns_stats())
     |> assign(:network_stats, get_network_stats())}
  end

  @impl true
  def handle_info({:service_registered, _service_id}, socket) do
    {:noreply,
     socket
     |> assign(:stats, get_mdns_stats())
     |> put_flash(:info, "Service registered successfully")}
  end

  @impl true
  def handle_info({:service_unregistered, _service_id}, socket) do
    {:noreply,
     socket
     |> assign(:stats, get_mdns_stats())
     |> put_flash(:info, "Service unregistered")}
  end

  @impl true
  def handle_info({:service_updated, _service_id}, socket) do
    {:noreply, assign(socket, :stats, get_mdns_stats())}
  end

  @impl true
  def handle_info(:network_update, socket) do
    {:noreply, assign(socket, :network_stats, get_network_stats())}
  end

  defp get_mdns_status do
    try do
      YellowDog.Mdns.status()
    catch
      kind, _ when kind in [:exit, :error] ->
        %{running: false, mode: :unknown, registered_services: 0, discovered_services: 0}
    end
  end

  defp get_mdns_stats do
    try do
      registry_stats = YellowDog.Mdns.ServiceRegistry.stats()
      %{registry_stats: registry_stats}
    catch
      kind, _ when kind in [:exit, :error] ->
        %{
          registry_stats: %{
            total: 0,
            enabled: 0,
            disabled: 0,
            registered: 0,
            from_file: 0
          }
        }
    end
  end

  defp get_network_stats do
    try do
      YellowDog.Mdns.network_stats()
    catch
      kind, _ when kind in [:exit, :error] ->
        %{
          total_responses: 0,
          total_queries: 0,
          active_services: 0,
          unique_hosts: 0,
          queries_per_minute: 0.0
        }
    end
  end
end
