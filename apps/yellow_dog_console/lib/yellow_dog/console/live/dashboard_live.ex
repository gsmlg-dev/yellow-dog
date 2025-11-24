defmodule YellowDog.Console.DashboardLive do
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Schedule periodic refresh every 5 seconds
      :timer.send_interval(5_000, self(), :refresh_services)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:services, get_service_status())}
  end

  @impl true
  def handle_info(:refresh_services, socket) do
    {:noreply, assign(socket, :services, get_service_status())}
  end

  # Service configuration
  @service_info %{
    dns: %{name: "DNS", description: "Domain Name Service", default_port: "53"},
    dhcpv4: %{name: "DHCPv4", description: "DHCP IPv4 Service", default_port: "67"},
    dhcpv6: %{name: "DHCPv6", description: "DHCP IPv6 Service", default_port: "547"},
    mdns: %{name: "mDNS", description: "Multicast DNS", default_port: "5353"}
  }

  defp get_service_status do
    try do
      # Get real status from YellowDog service manager
      all_status = YellowDog.get_all_status()

      # Transform to UI format
      [:dns, :dhcpv4, :dhcpv6, :mdns]
      |> Enum.map(fn service_key ->
        service_status = Map.get(all_status, service_key, %{})
        service_config = Map.get(@service_info, service_key)

        # Get port from config or use default
        port = get_service_port(service_status, service_config)

        # Build service map
        %{
          key: service_key,
          name: service_config.name,
          description: service_config.description,
          status: if(service_status[:running], do: "Running", else: "Stopped"),
          enabled: Map.get(service_status, :enabled, false),
          running: Map.get(service_status, :running, false),
          port: port,
          pid: format_pid(service_status[:pid]),
          memory: format_memory(service_status[:memory]),
          uptime: service_status[:uptime],
          children_count: service_status[:children_count],
          running_children: service_status[:running_children]
        }
      end)
    rescue
      e ->
        # Fallback to default status if service manager fails
        require Logger
        Logger.warning("Failed to get service status: #{inspect(e)}")
        get_fallback_status()
    end
  end

  defp get_service_port(service_status, service_config) do
    case service_status[:config] do
      config when is_map(config) ->
        case Map.get(config, "port") do
          port when is_integer(port) -> Integer.to_string(port)
          port when is_binary(port) -> port
          _ -> service_config.default_port
        end

      _ ->
        service_config.default_port
    end
  end

  defp format_pid(nil), do: "N/A"
  defp format_pid(pid) when is_pid(pid), do: inspect(pid)
  defp format_pid(pid), do: inspect(pid)

  defp format_memory(nil), do: "N/A"
  defp format_memory(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes}B"

  defp format_memory(bytes) when is_integer(bytes) and bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 2)}KB"

  defp format_memory(bytes) when is_integer(bytes) and bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 2)}MB"

  defp format_memory(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)}GB"

  defp format_memory(_), do: "N/A"

  defp get_fallback_status do
    # Return default status when service manager is unavailable
    Enum.map([:dns, :dhcpv4, :dhcpv6, :mdns], fn service_key ->
      service_config = Map.get(@service_info, service_key)

      %{
        key: service_key,
        name: service_config.name,
        description: service_config.description,
        status: "Unknown",
        enabled: false,
        running: false,
        port: service_config.default_port,
        pid: "N/A",
        memory: "N/A",
        uptime: nil,
        children_count: 0,
        running_children: 0
      }
    end)
  end
end
