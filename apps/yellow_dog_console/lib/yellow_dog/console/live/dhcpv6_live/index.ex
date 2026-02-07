defmodule YellowDog.Console.Dhcpv6Live.Index do
  @moduledoc """
  LiveView for DHCPv6 service overview.

  Displays service status, statistics (active IA_NA/IA_PD bindings, pool
  utilization), and recent DHCPv6 events. Subscribes to telemetry events
  for real-time updates when addresses/prefixes are delegated.
  """

  use YellowDog.Console, :live_view

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
    case Code.ensure_loaded?(YellowDog.Dhcpv6) do
      true ->
        try do
          YellowDog.Dhcpv6.stats()
        rescue
          _ ->
            default_stats()
        catch
          :exit, _ -> default_stats()
        end

      false ->
        default_stats()
    end
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
    case Code.ensure_loaded?(YellowDog.Dhcpv6) do
      true ->
        try do
          YellowDog.Dhcpv6.get_all_pool_stats()
        rescue
          _ -> %{}
        catch
          :exit, _ -> %{}
        end

      false ->
        %{}
    end
  end

  defp get_pools do
    case Code.ensure_loaded?(YellowDog.Dhcpv6.LeaseManager) do
      true ->
        try do
          YellowDog.Dhcpv6.LeaseManager.get_pools()
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      false ->
        []
    end
  end

  defp handle_telemetry_event(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp format_duid(duid) when is_binary(duid) do
    duid
    |> :binary.bin_to_list()
    |> Enum.map(fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_duid(_), do: "Unknown"

  defp format_ipv6({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(fn b -> b |> Integer.to_string(16) |> String.downcase() end)
    |> Enum.join(":")
  end

  defp format_ipv6(_), do: "Unknown"

  defp format_ia_type(:ia_na), do: "IA_NA (Non-temporary)"
  defp format_ia_type(:ia_ta), do: "IA_TA (Temporary)"
  defp format_ia_type(:ia_pd), do: "IA_PD (Prefix Delegation)"
  defp format_ia_type(type), do: to_string(type)

  defp get_ia_type_color(:ia_na), do: "text-primary"
  defp get_ia_type_color(:ia_ta), do: "text-secondary"
  defp get_ia_type_color(:ia_pd), do: "text-accent"
  defp get_ia_type_color(_), do: "text-base-content"

  defp get_utilization_color(percent) when percent >= 90, do: "error"
  defp get_utilization_color(percent) when percent >= 75, do: "warning"
  defp get_utilization_color(percent) when percent >= 50, do: "info"
  defp get_utilization_color(_), do: "success"

  defp get_state_text_color(:active), do: "text-success"
  defp get_state_text_color(:offered), do: "text-info"
  defp get_state_text_color(:released), do: "text-warning"
  defp get_state_text_color(:expired), do: "text-error"
  defp get_state_text_color(:declined), do: "text-error"
  defp get_state_text_color(_), do: "text-base-content"

  defp get_status do
    case Code.ensure_loaded?(YellowDog.Dhcpv6) do
      true ->
        try do
          YellowDog.Dhcpv6.status()
        rescue
          _ -> %{running: false}
        catch
          :exit, _ -> %{running: false}
        end

      false ->
        %{running: false}
    end
  end
end
