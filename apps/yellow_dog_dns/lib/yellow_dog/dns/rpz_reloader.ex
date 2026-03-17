defmodule YellowDog.Dns.RpzReloader do
  @moduledoc """
  Event consumer subscribed to `rpz:*` events via EventBridge.

  On any RPZ rule change, triggers reload of the RPZ ruleset in DNS
  worker processes so that new policy rules take effect immediately.
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
  def handle_info({:store_event, %{key: key}}, state) do
    if String.starts_with?(key, "rpz:") do
      handle_rpz_change(key)
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
    case YellowDog.Store.EventBridge.subscribe("rpz:*") do
      {:ok, ref} ->
        case Process.whereis(YellowDog.Store.EventBridge) do
          pid when is_pid(pid) ->
            mon = Process.monitor(pid)
            %{state | subscription_ref: ref, bridge_monitor: mon}

          nil ->
            %{state | subscription_ref: ref, bridge_monitor: nil}
        end

      _ ->
        Logger.warning("RpzReloader: failed to subscribe to EventBridge, retrying")
        Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
        state
    end
  rescue
    e ->
      Logger.warning("RpzReloader: EventBridge subscribe error: #{inspect(e)}")
      Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
      state
  end

  defp handle_rpz_change(key) do
    zone_name = extract_rpz_zone(key)

    Logger.debug("RpzReloader: RPZ change detected for zone #{zone_name}, triggering reload")

    :telemetry.execute(
      [:yellow_dog, :dns, :rpz, :reload],
      %{},
      %{zone: zone_name, trigger: :store_event}
    )
  end

  defp extract_rpz_zone(key) do
    key
    |> String.trim_leading("rpz:")
    |> String.split(":", parts: 2)
    |> List.first()
  end
end
