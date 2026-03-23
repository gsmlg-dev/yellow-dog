defmodule YellowDog.Dns.ZoneReloader do
  @moduledoc """
  Event consumer subscribed to `dns:view:*` events via EventBridge.

  On zone metadata or RR changes, triggers incremental reload of the
  affected zone in DNS worker processes. Handles all zone types:
  - Auth zone RR changes → reload records into ETS
  - Forward zone metadata changes → reload forwarders
  - Stub zone metadata changes → reload config and re-query primaries
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @resubscribe_delay_ms 1_000

  @impl true
  def init(_opts) do
    {:ok, subscribe_to_bridge(%{subscription_ref: nil, bridge_monitor: nil})}
  end

  @impl true
  def handle_info({:store_event, %{type: type, key: key}}, state)
      when type in [:put, :delete] do
    if String.starts_with?(key, "dns:view:") do
      handle_zone_change(key)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
    {:noreply, %{state | subscription_ref: nil, bridge_monitor: nil}}
  end

  def handle_info(:resubscribe, state) do
    {:noreply, subscribe_to_bridge(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{subscription_ref: ref}) when not is_nil(ref) do
    try do
      YellowDog.Store.EventBridge.unsubscribe(ref)
    rescue
      _ -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp subscribe_to_bridge(state) do
    case YellowDog.Store.EventBridge.subscribe("dns:view:*") do
      {:ok, ref} ->
        case Process.whereis(YellowDog.Store.EventBridge) do
          pid when is_pid(pid) ->
            mon = Process.monitor(pid)
            %{state | subscription_ref: ref, bridge_monitor: mon}

          nil ->
            %{state | subscription_ref: ref, bridge_monitor: nil}
        end

      _ ->
        Logger.warning("ZoneReloader: failed to subscribe to EventBridge, retrying")
        Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
        state
    end
  rescue
    e ->
      Logger.warning("ZoneReloader: EventBridge subscribe error: #{inspect(e)}")
      Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
      state
  end

  # Key format: dns:view:{view_name}:zone:{zone_name}[:rr:{owner}:{type}]
  defp handle_zone_change(key) do
    case parse_zone_key(key) do
      {:ok, view_name, zone_name, :metadata} ->
        Logger.debug(
          "ZoneReloader: zone metadata change for #{view_name}/#{zone_name}, triggering reload"
        )

        emit_reload_telemetry(zone_name, :store_event)
        trigger_reload(view_name, zone_name)

      {:ok, view_name, zone_name, :rr} ->
        Logger.debug("ZoneReloader: RR change for #{view_name}/#{zone_name}, triggering reload")

        emit_reload_telemetry(zone_name, :store_event)
        trigger_reload(view_name, zone_name)

      :error ->
        :ok
    end
  end

  # Parse dns:view:{view}:zone:{name}[:rr:{owner}:{type}]
  defp parse_zone_key(key) do
    case String.split(key, ":") do
      ["dns", "view", view_name, "zone", zone_name, "rr" | _rest] ->
        {:ok, view_name, zone_name, :rr}

      ["dns", "view", view_name, "zone", zone_name] ->
        {:ok, view_name, zone_name, :metadata}

      _ ->
        :error
    end
  end

  defp trigger_reload(view_name, zone_name) do
    try do
      # Try to find and reload each possible zone type
      for zone_type <- [:auth, :forward, :stub] do
        case YellowDog.Dns.ZoneController.find_zone(view_name, zone_type, zone_name) do
          {:ok, pid} ->
            module = zone_module(zone_type)
            module.reload(pid, [])

          :error ->
            :ok
        end
      end
    rescue
      _ -> :ok
    end
  end

  defp zone_module(:auth), do: YellowDog.Dns.Zone.Auth
  defp zone_module(:forward), do: YellowDog.Dns.Zone.Forward
  defp zone_module(:stub), do: YellowDog.Dns.Zone.Stub

  defp emit_reload_telemetry(zone_name, trigger) do
    :telemetry.execute(
      [:yellow_dog, :dns, :zone, :reload],
      %{},
      %{zone: zone_name, trigger: trigger}
    )
  end
end
