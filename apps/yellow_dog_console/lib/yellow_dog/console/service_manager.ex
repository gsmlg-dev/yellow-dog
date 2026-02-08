defmodule YellowDog.Console.ServiceManager do
  @moduledoc """
  Manages service lifecycle operations for web console.

  Provides safe restart mechanisms with configuration updates using OTP
  supervisor terminate-and-restart pattern.

  Based on research findings from research.md:
  - Update configuration in YellowDog.Config Agent
  - Terminate supervisor (OTP restarts automatically)
  - Monitor for restart completion
  - Verify service health
  """

  @termination_timeout 5_000
  @max_restart_attempts 10
  @backoff_base_ms 100
  @health_check_delay_ms 500

  @doc """
  Applies pending configuration for a service and restarts it.

  ## Steps
    1. Update configuration in YellowDog.Config Agent
    2. Get current supervisor PID for service
    3. Terminate supervisor (OTP will restart automatically)
    4. Monitor for restart completion
    5. Verify service health

  ## Parameters
    - service: Service atom (:dns, :mdns, :dhcpv4, :dhcpv6)
    - new_config: Map of new configuration values

  ## Returns
    - `:ok` if successful
    - `{:error, reason}` if restart failed

  ## Examples

      iex> new_config = %{enabled: true, listen: "0.0.0.0", port: 5353}
      iex> ServiceManager.apply_and_restart(:dns, new_config)
      :ok
  """
  @spec apply_and_restart(atom(), map()) :: :ok | {:error, term()}
  def apply_and_restart(service, new_config) do
    # First update the configuration
    case update_config(service, new_config) do
      :ok ->
        # Check if service is currently running
        case get_supervisor_pid(service) do
          {:ok, old_pid} ->
            # Service is running, restart it
            restart_running_service(service, old_pid)

          {:error, :supervisor_not_running} ->
            # Service is not running, try to start it if enabled
            if Map.get(new_config, "enabled", false) do
              start_service(service)
            else
              emit_action(service, :config_updated, :info)
              :ok
            end
        end

      {:error, reason} = error ->
        emit_telemetry(:service_restart_failed, %{service: service, reason: reason})
        emit_action(service, :config_update_failed, :error, reason: inspect(reason))
        error
    end
  end

  defp restart_running_service(service, old_pid) do
    with :ok <- terminate_supervisor(old_pid),
         {:ok, new_pid} <- wait_for_restart(service, old_pid),
         :ok <- verify_service_health(service, new_pid) do
      emit_telemetry(:service_restarted, %{service: service})
      emit_action(service, :restarted, :info)
      :ok
    else
      {:error, reason} = error ->
        emit_telemetry(:service_restart_failed, %{service: service, reason: reason})
        emit_action(service, :restart_failed, :error, reason: inspect(reason))
        error
    end
  end

  defp start_service(service) do
    emit_action(service, :starting, :info)

    case YellowDog.start_service(service) do
      :ok ->
        emit_telemetry(:service_started, %{service: service})
        emit_action(service, :started, :info)
        :ok

      {:error, reason} = error ->
        emit_telemetry(:service_start_failed, %{service: service, reason: reason})
        emit_action(service, :start_failed, :error, reason: inspect(reason))
        error
    end
  rescue
    e in UndefinedFunctionError ->
      emit_action(service, :start_not_available, :warning, error: inspect(e))
      {:error, :start_not_implemented}
  end

  # Private Functions

  defp update_config(service, new_config) do
    emit_action(service, :updating_config, :debug)
    YellowDog.Config.update(service, new_config)
  end

  defp get_supervisor_pid(service) do
    supervisor_name = supervisor_module(service)

    case Process.whereis(supervisor_name) do
      nil -> {:error, :supervisor_not_running}
      pid -> {:ok, pid}
    end
  end

  defp supervisor_module(:dns), do: YellowDog.Dns.Supervisor
  defp supervisor_module(:mdns), do: YellowDog.Mdns.Supervisor
  defp supervisor_module(:dhcpv4), do: YellowDog.Dhcpv4.Supervisor
  defp supervisor_module(:dhcpv6), do: YellowDog.Dhcpv6.Supervisor

  defp terminate_supervisor(pid) do
    # Monitor the process to detect termination
    ref = Process.monitor(pid)

    # Request termination via parent supervisor
    # Note: This assumes YellowDog.Application is the parent
    # In practice, we would use Supervisor.terminate_child
    send(pid, :shutdown)

    # Wait for DOWN message (with timeout)
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @termination_timeout -> {:error, :termination_timeout}
    end
  end

  defp wait_for_restart(service, old_pid, attempt \\ 1) do
    if attempt > @max_restart_attempts do
      {:error, :restart_timeout}
    else
      supervisor_name = supervisor_module(service)

      case Process.whereis(supervisor_name) do
        nil ->
          Process.sleep(@backoff_base_ms * attempt)
          wait_for_restart(service, old_pid, attempt + 1)

        ^old_pid ->
          Process.sleep(@backoff_base_ms * attempt)
          wait_for_restart(service, old_pid, attempt + 1)

        new_pid ->
          {:ok, new_pid}
      end
    end
  end

  defp verify_service_health(service, pid) do
    Process.sleep(@health_check_delay_ms)
    emit_action(service, :verifying_health, :debug)

    # Check if supervisor is still alive
    if Process.alive?(pid) do
      # Verify children are started
      case Supervisor.count_children(pid) do
        %{active: active} when active > 0 -> :ok
        _ -> {:error, :no_active_children}
      end
    else
      {:error, :supervisor_died}
    end
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:yellow_dog, :console, :service, event],
      %{timestamp: System.monotonic_time()},
      metadata
    )
  end

  defp emit_action(service, action, severity, extra \\ []) do
    metadata =
      %{source: __MODULE__, service: service, action: action, severity: severity}
      |> Map.merge(Map.new(extra))

    :telemetry.execute([:yellow_dog, :console, :service, :action], %{count: 1}, metadata)
  end
end
