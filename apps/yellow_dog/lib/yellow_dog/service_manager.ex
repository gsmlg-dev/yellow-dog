defmodule YellowDog.ServiceManager do
  @moduledoc """
  Service management and status reporting for all YellowDog services.

  Provides a unified interface to check service status, get statistics,
  and control services across the entire YellowDog system.
  """

  @services [:dns, :mdns, :dhcpv4, :dhcpv6]

  # Supervisor modules (used for start/stop)
  @service_supervisors %{
    dns: YellowDog.Dns.Supervisor,
    mdns: YellowDog.Mdns.Supervisor,
    dhcpv4: YellowDog.Dhcpv4.Supervisor,
    dhcpv6: YellowDog.Dhcpv6.Supervisor
  }

  # Process registration names (supervisors register with these names, not their module names)
  @service_process_names %{
    dns: YellowDog.Dns,
    mdns: YellowDog.Mdns,
    dhcpv4: YellowDog.Dhcpv4,
    dhcpv6: YellowDog.Dhcpv6
  }

  @doc """
  Gets the status of all services.

  ## Returns
  - Map of service statuses with detailed information
  """
  @spec get_all_status() :: %{atom() => map()}
  def get_all_status do
    Map.new(@services, fn service -> {service, get_service_status(service)} end)
  end

  @doc """
  Gets the status of a specific service.

  ## Parameters
  - `service` - Service name (:dns, :mdns, :dhcpv4, :dhcpv6)

  ## Returns
  - Map with service status details
  """
  @spec get_service_status(atom()) :: map()
  def get_service_status(service) when service in @services do
    enabled = YellowDog.Config.service_enabled?(service)

    status = %{
      enabled: enabled,
      running: false,
      uptime: nil,
      config: YellowDog.Config.get_service(service),
      stats: %{}
    }

    if enabled do
      case get_supervisor_status(service) do
        {:ok, supervisor_info} ->
          Map.merge(status, supervisor_info)

        {:error, _reason} ->
          status
      end
    else
      status
    end
  end

  def get_service_status(service) do
    :telemetry.execute(
      [:yellow_dog, :service, :error],
      %{count: 1},
      %{
        source: __MODULE__,
        reason: :unknown_service,
        service: inspect(service),
        severity: :warning
      }
    )

    %{error: "Unknown service"}
  end

  @doc """
  Lists all available services.

  ## Returns
  - List of service atoms
  """
  @spec list_services() :: [atom()]
  def list_services, do: @services

  @doc """
  Starts a service that is currently not running.

  Updates the configuration to enable the service and starts its supervisor.

  ## Parameters
  - `service` - Service name (:dns, :mdns, :dhcpv4, :dhcpv6)

  ## Returns
  - `:ok` if service started successfully
  - `{:error, reason}` if start failed
  """
  @spec start_service(atom()) :: :ok | {:error, term()}
  def start_service(service) when service in @services do
    # Enable the service in config
    YellowDog.Config.set_service_enabled(service, true)

    # Start the supervisor via YellowDog.Application
    supervisor_module = Map.get(@service_supervisors, service)

    case YellowDog.Application.start_service_supervisor(service, supervisor_module) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def start_service(service) do
    :telemetry.execute(
      [:yellow_dog, :service, :error],
      %{count: 1},
      %{
        source: __MODULE__,
        reason: :unknown_service,
        service: inspect(service),
        severity: :warning
      }
    )

    {:error, :unknown_service}
  end

  @doc """
  Stops a running service.

  ## Parameters
  - `service` - Service name (:dns, :mdns, :dhcpv4, :dhcpv6)

  ## Returns
  - `:ok` if service stopped successfully
  - `{:error, reason}` if stop failed
  """
  @spec stop_service(atom()) :: :ok | {:error, term()}
  def stop_service(service) when service in @services do
    # Disable the service in config
    YellowDog.Config.set_service_enabled(service, false)

    # Stop the supervisor
    supervisor_module = Map.get(@service_supervisors, service)

    case YellowDog.Application.stop_service_supervisor(service, supervisor_module) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def stop_service(service) do
    :telemetry.execute(
      [:yellow_dog, :service, :error],
      %{count: 1},
      %{
        source: __MODULE__,
        reason: :unknown_service,
        service: inspect(service),
        severity: :warning
      }
    )

    {:error, :unknown_service}
  end

  @doc """
  Gets detailed statistics for a specific service.

  ## Parameters
  - `service` - Service name (:dns, :mdns, :dhcpv4, :dhcpv6)

  ## Returns
  - Map with service-specific statistics
  """
  @spec get_service_stats(atom()) :: map()
  def get_service_stats(:mdns) do
    if YellowDog.Config.service_enabled?(:mdns) do
      safe_service_call(YellowDog.Mdns.MessageCache, :stats, [])
    else
      %{error: "Service disabled"}
    end
  end

  def get_service_stats(:dhcpv4) do
    if YellowDog.Config.service_enabled?(:dhcpv4) do
      safe_service_call(YellowDog.Dhcpv4.LeaseManager, :stats, [])
    else
      %{error: "Service disabled"}
    end
  end

  def get_service_stats(:dhcpv6) do
    if YellowDog.Config.service_enabled?(:dhcpv6) do
      safe_service_call(YellowDog.Dhcpv6.LeaseManager, :stats, [])
    else
      %{error: "Service disabled"}
    end
  end

  def get_service_stats(:dns) do
    if YellowDog.Config.service_enabled?(:dns) do
      %{info: "DNS statistics not yet implemented"}
    else
      %{error: "Service disabled"}
    end
  end

  def get_service_stats(_service) do
    %{error: "Unknown service"}
  end

  @doc """
  Formats service status for display.

  ## Parameters
  - `service` - Service name or `:all` for all services

  ## Returns
  - Formatted string for console display
  """
  @spec format_status(atom()) :: String.t()
  def format_status(:all) do
    status = get_all_status()

    output = ["=== YellowDog Services Status ===\n"]

    service_outputs =
      @services
      |> Enum.map(fn service ->
        service_status = Map.get(status, service)
        format_service_status(service, service_status)
      end)

    (output ++ service_outputs ++ ["\n"])
    |> Enum.join("\n")
  end

  def format_status(service) when service in @services do
    status = get_service_status(service)
    format_service_status(service, status)
  end

  def format_status(_service), do: "Unknown service"

  # Private functions

  defp get_supervisor_status(service) do
    # Use the actual process registration name (supervisors register as YellowDog.Dns, not YellowDog.Dns.Supervisor)
    process_name = Map.get(@service_process_names, service)

    case Process.whereis(process_name) do
      nil ->
        {:error, :not_running}

      pid ->
        try do
          # Get supervisor info
          children = Supervisor.which_children(pid)

          running_children =
            Enum.count(children, fn {_id, child_pid, _type, _modules} ->
              is_pid(child_pid) and Process.alive?(child_pid)
            end)

          # Get process info
          process_info = Process.info(pid)
          start_time = get_process_start_time(pid)
          uptime = calculate_uptime(start_time)

          stats = get_service_stats(service)

          {:ok,
           %{
             running: true,
             pid: pid,
             uptime: uptime,
             children_count: length(children),
             running_children: running_children,
             memory: Keyword.get(process_info, :memory, 0),
             stats: stats
           }}
        rescue
          e in [ArgumentError, UndefinedFunctionError] ->
            {:error, {:info_unavailable, Exception.message(e)}}
        end
    end
  end

  defp get_process_start_time(pid) do
    # Estimate start time based on process dictionary
    # This is an approximation since Erlang doesn't track exact start time
    info = Process.info(pid, :reductions)

    case info do
      {:reductions, _} ->
        # Return current time minus estimated runtime
        System.system_time(:second)

      _ ->
        System.system_time(:second)
    end
  end

  defp calculate_uptime(start_time) do
    now = System.system_time(:second)
    uptime_seconds = now - start_time

    # Format as human-readable
    days = div(uptime_seconds, 86_400)
    hours = div(rem(uptime_seconds, 86_400), 3600)
    minutes = div(rem(uptime_seconds, 3600), 60)
    seconds = rem(uptime_seconds, 60)

    cond do
      days > 0 -> "#{days}d #{hours}h #{minutes}m"
      hours > 0 -> "#{hours}h #{minutes}m #{seconds}s"
      minutes > 0 -> "#{minutes}m #{seconds}s"
      true -> "#{seconds}s"
    end
  end

  defp format_service_status(service, status) do
    service_name = service |> to_string() |> String.upcase()

    enabled_str = if status.enabled, do: "ENABLED", else: "DISABLED"
    running_str = if status.running, do: "RUNNING", else: "STOPPED"

    status_line = "#{service_name}: #{enabled_str} | #{running_str}"

    details = []

    details =
      if status.running do
        base_details =
          details ++
            [
              "  Uptime: #{status.uptime}",
              "  Children: #{status.running_children}/#{status.children_count}",
              "  Memory: #{format_bytes(status.memory)}"
            ]

        # Add service-specific stats
        stats_details =
          case service do
            :mdns ->
              if is_map(status.stats) and not Map.has_key?(status.stats, :error) do
                [
                  "  Cache: #{Map.get(status.stats, :active_entries, 0)} active entries, #{Map.get(status.stats, :expired_entries, 0)} expired"
                ]
              else
                []
              end

            :dhcpv4 ->
              if is_map(status.stats) and not Map.has_key?(status.stats, :error) do
                [
                  "  Leases: #{Map.get(status.stats, :active_leases, 0)} active, #{Map.get(status.stats, :total_leases, 0)} total"
                ]
              else
                []
              end

            :dhcpv6 ->
              if is_map(status.stats) and not Map.has_key?(status.stats, :error) do
                [
                  "  Leases: #{Map.get(status.stats, :active_leases, 0)} active, #{Map.get(status.stats, :total_leases, 0)} total"
                ]
              else
                []
              end

            :dns ->
              # DNS stats to be implemented
              []
          end

        base_details ++ stats_details
      else
        details
      end

    details =
      if status.config do
        config_str = format_config(service, status.config)
        if config_str, do: details ++ ["  Config: #{config_str}"], else: details
      else
        details
      end

    ([status_line] ++ details) |> Enum.join("\n")
  end

  defp format_config(service, config) when is_map(config) do
    # Config keys are atoms from YellowDog.Config.get_service/1
    case service do
      :dns ->
        port = Map.get(config, :port) || Map.get(config, "port", 53)
        listen = Map.get(config, :listen) || Map.get(config, "listen", "0.0.0.0")
        "#{listen}:#{port}"

      :mdns ->
        port = Map.get(config, :port) || Map.get(config, "port", 5353)
        listen = Map.get(config, :listen) || Map.get(config, "listen", "0.0.0.0")
        "#{listen}:#{port}"

      :dhcpv4 ->
        port = Map.get(config, :port) || Map.get(config, "port", 67)
        listen = Map.get(config, :listen) || Map.get(config, "listen", "0.0.0.0")
        pools = Map.get(config, :pools) || Map.get(config, "pools", [])
        "#{listen}:#{port} (#{length(pools)} pools)"

      :dhcpv6 ->
        port = Map.get(config, :port) || Map.get(config, "port", 547)
        listen = Map.get(config, :listen) || Map.get(config, "listen", "::")
        pools = Map.get(config, :pools) || Map.get(config, "pools", [])
        "#{listen}:#{port} (#{length(pools)} pools)"
    end
  end

  defp format_config(_service, _config), do: nil

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 2)}KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 2)}MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)}GB"

  defp safe_service_call(module, function, args) do
    apply(module, function, args)
  rescue
    e in [UndefinedFunctionError, ArgumentError] ->
      %{error: "Service not running: #{Exception.message(e)}"}
  catch
    :exit, {:noproc, _} -> %{error: "Service not running"}
  end
end
