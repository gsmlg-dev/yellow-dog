defmodule YellowDog.Console.Dhcpv4Live.Index do
  use YellowDog.Console, :live_view

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
    case Code.ensure_loaded?(YellowDog.Dhcpv4) do
      true ->
        try do
          YellowDog.Dhcpv4.stats()
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
      by_state: %{}
    }
  end

  defp get_pool_stats do
    case Code.ensure_loaded?(YellowDog.Dhcpv4) do
      true ->
        try do
          YellowDog.Dhcpv4.get_all_pool_stats()
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
    case Code.ensure_loaded?(YellowDog.Dhcpv4.LeaseManager) do
      true ->
        try do
          YellowDog.Dhcpv4.LeaseManager.get_pools()
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

  defp format_mac(<<mac::binary-size(6)>>) do
    mac
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_mac(_), do: "Unknown"

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(_), do: "Unknown"

  defp get_utilization_color(percent) when percent >= 90, do: "error"
  defp get_utilization_color(percent) when percent >= 75, do: "warning"
  defp get_utilization_color(percent) when percent >= 50, do: "info"
  defp get_utilization_color(_), do: "success"

  defp get_state_color(:active), do: "success"
  defp get_state_color(:offered), do: "info"
  defp get_state_color(:released), do: "warning"
  defp get_state_color(:expired), do: "error"
  defp get_state_color(:declined), do: "error"
  defp get_state_color(_), do: "ghost"

  defp get_state_text_color(:active), do: "text-success"
  defp get_state_text_color(:offered), do: "text-info"
  defp get_state_text_color(:released), do: "text-warning"
  defp get_state_text_color(:expired), do: "text-error"
  defp get_state_text_color(:declined), do: "text-error"
  defp get_state_text_color(_), do: "text-base-content"
end
