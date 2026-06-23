defmodule YellowDog.DnsProvider.ConfigWatcher do
  @moduledoc """
  EventBridge consumer that watches `dns:provider:*` key changes.

  On `:put` of a config key, stops any existing engine and starts a
  new one. On `:delete`, stops the engine. On boot, starts all
  enabled providers from the Store.
  """

  use GenServer

  require Logger

  alias YellowDog.DnsProvider.{Config, SyncSupervisor}

  @resubscribe_delay_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    state = %{subscription_ref: nil, bridge_monitor: nil}
    state = subscribe_to_bridge(state)
    boot_providers()
    {:ok, state}
  end

  @impl true
  def handle_info({:store_event, %{type: type, key: key}}, state)
      when type in [:put, :delete] do
    if String.starts_with?(key, "dns:provider:") and String.ends_with?(key, ":config") do
      handle_config_change(type, key)
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

  # -------------------------------------------------------------------
  # Internals
  # -------------------------------------------------------------------

  defp subscribe_to_bridge(state) do
    case YellowDog.Store.EventBridge.subscribe("dns:provider:*") do
      {:ok, ref} ->
        case Process.whereis(YellowDog.Store.EventBridge) do
          pid when is_pid(pid) ->
            mon = Process.monitor(pid)
            %{state | subscription_ref: ref, bridge_monitor: mon}

          nil ->
            %{state | subscription_ref: ref, bridge_monitor: nil}
        end

      _ ->
        Logger.warning("ConfigWatcher: failed to subscribe to EventBridge, retrying")
        Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
        state
    end
  rescue
    e ->
      Logger.warning("ConfigWatcher: EventBridge subscribe error: #{inspect(e)}")
      Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
      state
  end

  defp boot_providers do
    case YellowDog.Store.Provider.list_configs() do
      {:ok, configs} ->
        Enum.each(configs, fn config ->
          if Map.get(config, :enabled, true), do: start_from_map(config)
        end)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("ConfigWatcher: boot_providers error: #{inspect(e)}")
  end

  defp handle_config_change(:put, key) do
    name = extract_provider_name(key)
    SyncSupervisor.stop_engine(name)

    case YellowDog.Store.Provider.get_config(name) do
      {:ok, config_map} ->
        if Map.get(config_map, :enabled, true), do: start_from_map(config_map)

      _ ->
        :ok
    end
  end

  defp handle_config_change(:delete, key) do
    name = extract_provider_name(key)
    SyncSupervisor.stop_engine(name)
  end

  defp start_from_map(config_map) do
    case Config.from_map(config_map) do
      {:ok, config} ->
        case provider_module_for(config.type) do
          nil ->
            Logger.warning("ConfigWatcher: unknown provider type #{inspect(config.type)}")

          module ->
            case SyncSupervisor.start_engine(config, module) do
              {:ok, _pid} ->
                Logger.info("ConfigWatcher: started engine for #{config.name}")

              {:error, reason} ->
                Logger.warning(
                  "ConfigWatcher: failed to start engine for #{config.name}: #{inspect(reason)}"
                )
            end
        end

      {:error, reason} ->
        Logger.warning("ConfigWatcher: invalid config: #{inspect(reason)}")
    end
  end

  # Key format: dns:provider:{name}:config
  defp extract_provider_name(key) do
    key
    |> String.replace_prefix("dns:provider:", "")
    |> String.replace_suffix(":config", "")
  end

  defp provider_module_for(:iana_root), do: YellowDog.DnsProvider.Provider.IanaRoot
  defp provider_module_for(:aws), do: YellowDog.DnsProvider.Provider.Aws
  defp provider_module_for(:cloudflare), do: YellowDog.DnsProvider.Provider.Cloudflare
  defp provider_module_for(:gcp), do: YellowDog.DnsProvider.Provider.Gcp
  defp provider_module_for(:vultr), do: YellowDog.DnsProvider.Provider.Vultr
  defp provider_module_for(_), do: nil
end
