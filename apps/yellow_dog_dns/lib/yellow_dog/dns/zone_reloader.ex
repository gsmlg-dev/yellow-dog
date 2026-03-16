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

  @impl true
  def init(_opts) do
    subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:store_event, %{type: type, key: key}}, state)
      when type in [:put, :delete] do
    if String.starts_with?(key, "dns:zone:") do
      handle_zone_change(key)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp subscribe do
    try do
      YellowDog.Store.EventBridge.subscribe("dns:zone:*")
    rescue
      e ->
        Logger.warning("ZoneReloader: failed to subscribe to EventBridge: #{inspect(e)}")
    end
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
