defmodule YellowDog.ServiceHeartbeat do
  @moduledoc """
  Periodic heartbeat and status logger for YellowDog services.

  Emits debug-level telemetry logs at regular intervals for each running service,
  providing visibility into service health and activity in the real-time logs page.

  ## Configuration

  The heartbeat interval can be configured (default: 30 seconds):

      # In your config
      config :yellow_dog, :heartbeat_interval, 15_000  # 15 seconds

  ## Emitted Events

  For each running service, emits telemetry logs with:
  - Service status (running/stopped)
  - Uptime information
  - Service-specific statistics (leases, cache entries, etc.)
  """

  use GenServer

  alias YellowDog.Telemetry

  @default_interval 30_000

  # Client API

  @doc """
  Starts the service heartbeat.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the current heartbeat interval in milliseconds.
  """
  @spec get_interval() :: pos_integer()
  def get_interval do
    GenServer.call(__MODULE__, :get_interval)
  end

  @doc """
  Sets a new heartbeat interval in milliseconds.
  """
  @spec set_interval(pos_integer()) :: :ok
  def set_interval(interval) when interval > 0 do
    GenServer.call(__MODULE__, {:set_interval, interval})
  end

  @doc """
  Triggers an immediate heartbeat (useful for testing).
  """
  @spec heartbeat_now() :: :ok
  def heartbeat_now do
    GenServer.cast(__MODULE__, :heartbeat_now)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, get_configured_interval())
    start_time = System.monotonic_time(:second)

    # Schedule first heartbeat after a short delay to let services start
    Process.send_after(self(), :heartbeat, 1_000)

    {:ok, %{interval: interval, start_time: start_time, timer_ref: nil}}
  end

  @impl true
  def handle_call(:get_interval, _from, state) do
    {:reply, state.interval, state}
  end

  @impl true
  def handle_call({:set_interval, interval}, _from, state) do
    # Cancel existing timer and schedule with new interval
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :heartbeat, interval)
    {:reply, :ok, %{state | interval: interval, timer_ref: timer_ref}}
  end

  @impl true
  def handle_cast(:heartbeat_now, state) do
    emit_heartbeats()
    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    emit_heartbeats()

    # Schedule next heartbeat
    timer_ref = Process.send_after(self(), :heartbeat, state.interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  # Private Functions

  defp get_configured_interval do
    Application.get_env(:yellow_dog, :heartbeat_interval, @default_interval)
  end

  defp emit_heartbeats do
    services = [:dns, :mdns, :dhcpv4, :dhcpv6]

    Enum.each(services, fn service ->
      emit_service_heartbeat(service)
    end)
  end

  defp emit_service_heartbeat(:dns) do
    case safe_call(YellowDog.Dns, :status, []) do
      %{running: true} = status ->
        stats = safe_call(YellowDog.Dns, :stats, []) || %{}

        Telemetry.debug("DNS heartbeat", %{
          service: :dns,
          status: :running,
          zones: get_in(stats, [:zones, :count]) || 0,
          views: get_in(stats, [:views, :view_count]) || 0,
          connections: get_in(stats, [:connections, :active]) || 0,
          info: status[:info]
        })

      _ ->
        :ok
    end
  end

  defp emit_service_heartbeat(:mdns) do
    case safe_call(YellowDog.Mdns, :status, []) do
      %{running: true} = status ->
        Telemetry.debug("mDNS heartbeat", %{
          service: :mdns,
          status: :running,
          mode: status[:mode],
          registered_services: status[:registered_services] || 0,
          discovered_services: status[:discovered_services] || 0,
          active_services: get_in(status, [:network_stats, :active_services]) || 0
        })

      _ ->
        :ok
    end
  end

  defp emit_service_heartbeat(:dhcpv4) do
    case safe_call(YellowDog.Dhcpv4, :status, []) do
      %{running: true} ->
        stats = safe_call(YellowDog.Dhcpv4, :stats, []) || %{}

        Telemetry.debug("DHCPv4 heartbeat", %{
          service: :dhcpv4,
          status: :running,
          total_leases: stats[:total_leases] || 0,
          active_leases: stats[:active_leases] || 0,
          expired_leases: stats[:expired_leases] || 0
        })

      _ ->
        :ok
    end
  end

  defp emit_service_heartbeat(:dhcpv6) do
    case safe_call(YellowDog.Dhcpv6, :status, []) do
      %{running: true} ->
        stats = safe_call(YellowDog.Dhcpv6, :stats, []) || %{}

        Telemetry.debug("DHCPv6 heartbeat", %{
          service: :dhcpv6,
          status: :running,
          total_leases: stats[:total_leases] || 0,
          active_leases: stats[:active_leases] || 0,
          expired_leases: stats[:expired_leases] || 0
        })

      _ ->
        :ok
    end
  end

  # Safely call a function, returning nil if the module isn't loaded or the call fails
  defp safe_call(module, function, args) do
    if Code.ensure_loaded?(module) do
      try do
        apply(module, function, args)
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end
    else
      nil
    end
  end
end
