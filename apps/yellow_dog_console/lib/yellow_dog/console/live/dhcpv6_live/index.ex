defmodule YellowDog.Console.Dhcpv6Live.Index do
  @moduledoc """
  LiveView for DHCPv6 service overview.

  Displays service status, statistics (active IA_NA/IA_PD bindings, pool
  utilization), and recent DHCPv6 events. Subscribes to telemetry events
  for real-time updates when addresses/prefixes are delegated.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.FormatHelper
  import YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to DHCPv6 telemetry events for real-time updates
      :telemetry.attach(
        "dhcpv6-live-#{inspect(self())}",
        [:yellow_dog, :dhcpv6, :lease_allocated],
        &handle_telemetry_event/4,
        %{pid: self()}
      )
    end

    {:ok,
     socket
     |> assign(:page_title, "DHCPv6 Overview")
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("dhcpv6-live-#{inspect(self())}")
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
    safe_call(YellowDog.Dhcpv6, fn -> YellowDog.Dhcpv6.stats() end, default_stats())
  end

  defp default_stats do
    %{
      total_leases: 0,
      active_leases: 0,
      expired_leases: 0,
      by_state: %{},
      by_ia_type: %{}
    }
  end

  defp get_pool_stats do
    safe_call(YellowDog.Dhcpv6, fn -> YellowDog.Dhcpv6.get_all_pool_stats() end, %{})
  end

  defp get_pools do
    safe_call(
      YellowDog.Dhcpv6.LeaseManager,
      fn -> YellowDog.Dhcpv6.LeaseManager.get_pools() end,
      []
    )
  end

  defp handle_telemetry_event(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp format_ia_type_verbose(:ia_na), do: "IA_NA (Non-temporary)"
  defp format_ia_type_verbose(:ia_ta), do: "IA_TA (Temporary)"
  defp format_ia_type_verbose(:ia_pd), do: "IA_PD (Prefix Delegation)"
  defp format_ia_type_verbose(type), do: to_string(type)

  defp get_status do
    safe_call(YellowDog.Dhcpv6, fn -> YellowDog.Dhcpv6.status() end, %{running: false})
  end
end
