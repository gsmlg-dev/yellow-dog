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

  @doc "Synchronously reconciles a provider engine with its persisted config."
  @spec reconcile(String.t()) :: :ok | {:error, term()}
  def reconcile(name) when is_binary(name) do
    case YellowDog.Store.Provider.get_config(name) do
      {:ok, config_map} -> reconcile_config(config_map)
      {:error, :not_found} -> ensure_stopped(name)
      {:error, _reason} = error -> error
      _ -> {:error, :apply_failed}
    end
  rescue
    _exception -> {:error, :apply_failed}
  catch
    :exit, _reason -> {:error, :apply_failed}
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
          reconcile(Map.get(config, :name))
        end)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("ConfigWatcher: boot_providers error: #{inspect(e)}")
  end

  defp handle_config_change(:put, key) do
    reconcile_and_log(extract_provider_name(key))
  end

  defp handle_config_change(:delete, key) do
    reconcile_and_log(extract_provider_name(key))
  end

  defp reconcile_and_log(name) do
    case reconcile(name) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("ConfigWatcher: reconcile failed for #{name}: #{inspect(reason)}")
    end
  end

  defp reconcile_config(config_map) do
    case Config.from_map(config_map) do
      {:ok, config} ->
        if config.enabled do
          reconcile_running(config)
        else
          ensure_stopped(config.name)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_running(config) do
    case running_config(config.name) do
      {:ok, ^config} ->
        :ok

      {:ok, _other} ->
        with :ok <- ensure_stopped(config.name), do: start_and_verify(config)

      :error ->
        start_and_verify(config)
    end
  end

  defp start_and_verify(config) do
    case provider_module_for(config.type) do
      nil ->
        {:error, :invalid_type}

      module ->
        case SyncSupervisor.start_engine(config, module) do
          {:ok, _pid} -> verify_running(config)
          {:error, _reason} -> {:error, :apply_failed}
        end
    end
  end

  defp verify_running(config) do
    case running_config(config.name) do
      {:ok, ^config} -> :ok
      _ -> {:error, :apply_failed}
    end
  end

  defp ensure_stopped(name) do
    case SyncSupervisor.stop_engine(name) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} -> {:error, :apply_failed}
    end
  rescue
    ArgumentError -> :ok
  end

  defp running_config(name) do
    case Registry.lookup(YellowDog.DnsProvider.Registry, name) do
      [{pid, _}] when is_pid(pid) -> {:ok, :sys.get_state(pid).config}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  # Key format: dns:provider:{name}:config
  defp extract_provider_name(key) do
    key
    |> String.replace_prefix("dns:provider:", "")
    |> String.replace_suffix(":config", "")
  end

  defp provider_module_for(:iana_root), do: YellowDog.DnsProvider.Provider.IanaRoot
  defp provider_module_for(:aws), do: YellowDog.DnsProvider.Provider.Aws
  defp provider_module_for(:route53), do: YellowDog.DnsProvider.Provider.Aws
  defp provider_module_for(:cloudflare), do: YellowDog.DnsProvider.Provider.Cloudflare
  defp provider_module_for(:gcp), do: YellowDog.DnsProvider.Provider.Gcp
  defp provider_module_for(:vultr), do: YellowDog.DnsProvider.Provider.Vultr
  defp provider_module_for(_), do: nil
end
