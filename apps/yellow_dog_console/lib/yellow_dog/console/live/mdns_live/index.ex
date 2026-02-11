defmodule YellowDog.Console.MdnsLive.Index do
  @moduledoc """
  mDNS overview page showing status, statistics, and quick actions.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to service updates
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:services")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:monitor")
    end

    {:ok,
     assign(socket,
       page_title: "mDNS Service",
       service_running: service_running?(YellowDog.Mdns),
       status: get_mdns_status(),
       stats: get_mdns_stats(),
       network_stats: get_network_stats()
     )}
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     assign(socket,
       status: get_mdns_status(),
       stats: get_mdns_stats(),
       network_stats: get_network_stats()
     )}
  end

  defp get_mdns_status do
    safe_call(YellowDog.Mdns, fn -> YellowDog.Mdns.status() end, %{
      running: false,
      mode: :unknown,
      registered_services: 0,
      discovered_services: 0
    })
  end

  defp get_mdns_stats do
    safe_call(
      YellowDog.Mdns.ServiceRegistry,
      fn -> %{registry_stats: YellowDog.Mdns.ServiceRegistry.stats()} end,
      %{registry_stats: %{total: 0, enabled: 0, disabled: 0, registered: 0, from_file: 0}}
    )
  end

  defp get_network_stats do
    safe_call(YellowDog.Mdns, fn -> YellowDog.Mdns.network_stats() end, %{
      total_responses: 0,
      total_queries: 0,
      active_services: 0,
      unique_hosts: 0,
      queries_per_minute: 0.0
    })
  end
end
