defmodule YellowDog.Dns.ZoneReloader do
  @moduledoc """
  Event consumer subscribed to `dns:zone:*` events via EventBridge.

  On zone metadata or RR changes, triggers incremental reload of the
  affected zone in DNS worker processes. For RR changes, also ensures
  SOA serial is incremented.
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
    if String.starts_with?(key, "dns:zone:") do
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
    case YellowDog.Store.EventBridge.subscribe("dns:zone:*") do
      {:ok, ref} ->
        mon = Process.monitor(Process.whereis(YellowDog.Store.EventBridge))
        %{state | subscription_ref: ref, bridge_monitor: mon}

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

  defp handle_zone_change(key) do
    zone_name = extract_zone_name(key)

    Logger.debug("ZoneReloader: zone change detected for #{zone_name}, triggering reload")

    :telemetry.execute(
      [:yellow_dog, :dns, :zone, :reload],
      %{},
      %{zone: zone_name, trigger: :store_event}
    )

    try do
      if Process.whereis(YellowDog.Dns.ZoneController) do
        GenServer.cast(YellowDog.Dns.ZoneController, {:reload_zone, zone_name})
      end
    rescue
      _ -> :ok
    end
  end

  defp extract_zone_name(key) do
    key
    |> String.trim_leading("dns:zone:")
    |> String.split(":rr:", parts: 2)
    |> List.first()
  end
end
