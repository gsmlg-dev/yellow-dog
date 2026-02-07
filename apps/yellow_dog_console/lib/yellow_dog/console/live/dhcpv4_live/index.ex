defmodule YellowDog.Console.Dhcpv4Live.Index do
  @moduledoc """
  LiveView for DHCPv4 service overview.

  Displays service status, statistics (active leases, pool utilization),
  and recent DHCP events. Subscribes to telemetry events for real-time
  updates when leases are allocated or released.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.FormatHelper
  import YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to DHCP telemetry events for real-time updates
      :telemetry.attach(
        "dhcpv4-live-#{inspect(self())}",
        [:yellow_dog, :dhcpv4, :lease_allocated],
        &handle_telemetry_event/4,
        %{pid: self()}
      )
    end

    {:ok,
     socket
     |> assign(:page_title, "DHCPv4 Overview")
     |> assign(:last_event, nil)
     |> assign(:status, get_status())
     |> load_dhcp_data()}
  end

  @impl true
  def handle_info({:telemetry_event, event, _measurements, metadata}, socket) do
    {:noreply,
     socket
     |> assign(:last_event, %{event: event, time: DateTime.utc_now(), metadata: metadata})
     |> load_dhcp_data()}
  end

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("dhcpv4-live-#{inspect(self())}")
    :ok
  end

  # Private Functions

  defp load_dhcp_data(socket) do
    stats = get_dhcp_stats()
    pool_stats = get_pool_stats()
    pools = get_pools()

    socket
    |> assign(:stats, stats)
    |> assign(:pool_stats, pool_stats)
    |> assign(:pools, pools)
  end

  defp get_dhcp_stats do
    safe_call(YellowDog.Dhcpv4, fn -> YellowDog.Dhcpv4.stats() end, default_stats())
  end

  defp default_stats do
    %{
      total_leases: 0,
      active_leases: 0,
      expired_leases: 0,
      by_state: %{}
    }
  end

  defp get_pool_stats do
    safe_call(YellowDog.Dhcpv4, fn -> YellowDog.Dhcpv4.get_all_pool_stats() end, %{})
  end

  defp get_pools do
    safe_call(
      YellowDog.Dhcpv4.LeaseManager,
      fn -> YellowDog.Dhcpv4.LeaseManager.get_pools() end,
      []
    )
  end

  defp handle_telemetry_event(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp get_status do
    safe_call(YellowDog.Dhcpv4, fn -> YellowDog.Dhcpv4.status() end, %{running: false})
  end
end
