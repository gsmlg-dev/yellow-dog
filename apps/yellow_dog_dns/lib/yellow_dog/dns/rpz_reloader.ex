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

  @impl true
  def init(_opts) do
    subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:store_event, _action, key, _value}, state) do
    if String.starts_with?(key, "rpz:") do
      handle_rpz_change(key)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp subscribe do
    try do
      YellowDog.Store.EventBridge.subscribe("rpz:*")
    rescue
      e ->
        Logger.warning("RpzReloader: failed to subscribe to EventBridge: #{inspect(e)}")
    end
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
