defmodule YellowDog.Console.DashboardLive do
  @moduledoc """
  LiveView for the main service dashboard.

  Displays real-time status of all YellowDog services (DNS, mDNS, DHCPv4, DHCPv6)
  with auto-refresh every 5 seconds. Shows running/stopped state, uptime,
  and provides start/stop controls for each service.
  """

  use YellowDog.Console, :live_view

  import YellowDog.ConfigHelpers, only: [get_value: 2]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Schedule periodic refresh every 5 seconds
      :timer.send_interval(5_000, self(), :refresh_services)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:services, get_service_status())
     |> assign(:system_health, get_system_health())}
  end

  @impl true
  def handle_info(:refresh_services, socket) do
    {:noreply,
     socket
     |> assign(:services, get_service_status())
     |> assign(:system_health, get_system_health())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:services, get_service_status())
     |> assign(:system_health, get_system_health())}
  end

  @valid_services ~w(dns mdns dhcpv4 dhcpv6)

  @impl true
  def handle_event("start_service", %{"service" => service_str}, socket)
      when service_str in @valid_services do
    service = String.to_existing_atom(service_str)

    case YellowDog.start_service(service) do
      :ok ->
        {:noreply,
         socket
         |> assign(:services, get_service_status())
         |> put_flash(:info, "#{String.upcase(service_str)} started successfully")}

      {:error, {:already_started, _pid}} ->
        {:noreply,
         socket
         |> assign(:services, get_service_status())
         |> put_flash(:info, "#{String.upcase(service_str)} is already running")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to start #{String.upcase(service_str)}: #{inspect(reason)}"
         )}
    end
  end

  @impl true
  def handle_event("start_service", _params, socket) do
    {:noreply, put_flash(socket, :error, "Invalid service name")}
  end

  @impl true
  def handle_event("stop_service", %{"service" => service_str}, socket)
      when service_str in @valid_services do
    service = String.to_existing_atom(service_str)

    case YellowDog.stop_service(service) do
      :ok ->
        {:noreply,
         socket
         |> assign(:services, get_service_status())
         |> put_flash(:info, "#{String.upcase(service_str)} stopped successfully")}

      {:error, :not_running} ->
        {:noreply,
         socket
         |> assign(:services, get_service_status())
         |> put_flash(:info, "#{String.upcase(service_str)} is not running")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to stop #{String.upcase(service_str)}: #{inspect(reason)}"
         )}
    end
  end

  @impl true
  def handle_event("stop_service", _params, socket) do
    {:noreply, put_flash(socket, :error, "Invalid service name")}
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

        # Get error status if present
        error = Map.get(service_status, :error)

        # Determine status text
        status =
          cond do
            error != nil -> "Error"
            service_status[:running] -> "Running"
            true -> "Stopped"
          end

        # Build service map
        %{
          key: service_key,
          name: service_config.name,
          description: service_config.description,
          status: status,
          enabled: Map.get(service_status, :enabled, false),
          running: Map.get(service_status, :running, false),
          error: error,
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
        :telemetry.execute(
          [:yellow_dog, :console, :dashboard, :status_error],
          %{count: 1},
          %{source: __MODULE__, error: inspect(e), severity: :warning}
        )

        get_fallback_status()
    catch
      :exit, _ -> get_fallback_status()
    end
  end

  defp get_service_port(service_status, service_config) do
    case service_status[:config] do
      config when is_map(config) ->
        # Config keys are atoms from YellowDog.Config.get_service/1
        case get_value(config, :port) do
          port when is_integer(port) -> Integer.to_string(port)
          port when is_binary(port) -> port
          _ -> service_config.default_port
        end

      _ ->
        service_config.default_port
    end
  end

  defp format_pid(nil), do: "N/A"
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

  defp get_system_health do
    memory = :erlang.memory()
    total_memory = memory[:total] || 0
    process_memory = memory[:processes] || 0
    system_memory = memory[:system] || 0
    process_count = :erlang.system_info(:process_count)
    process_limit = :erlang.system_info(:process_limit)
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    # Memory percentage: process memory relative to total VM memory
    memory_pct = if total_memory > 0, do: round(process_memory / total_memory * 100), else: 0

    # Process utilization
    process_pct = if process_limit > 0, do: round(process_count / process_limit * 100), else: 0

    %{
      memory_total: format_memory(total_memory),
      memory_processes: format_memory(process_memory),
      memory_system: format_memory(system_memory),
      memory_pct: memory_pct,
      process_count: process_count,
      process_limit: process_limit,
      process_pct: process_pct,
      uptime: format_uptime(uptime_ms)
    }
  end

  defp format_uptime(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"

  defp format_uptime(ms) when ms < 3_600_000,
    do: "#{div(ms, 60_000)}m #{div(rem(ms, 60_000), 1_000)}s"

  defp format_uptime(ms) do
    hours = div(ms, 3_600_000)
    mins = div(rem(ms, 3_600_000), 60_000)
    "#{hours}h #{mins}m"
  end

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
        error: nil,
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
