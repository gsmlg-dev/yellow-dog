defmodule YellowDog.Store.ConfigWatcher do
  @moduledoc """
  Reusable GenServer that subscribes to `config:*` events via EventBridge
  and invokes a callback when configuration changes for a specific service.

  Each service app starts its own ConfigWatcher filtered to its namespace:

      # In your supervision tree:
      {YellowDog.Store.ConfigWatcher,
        service: :dns,
        handler: &YellowDog.Dns.Config.handle_change/2}

  The handler receives `(key, value)` where `key` is the config key name
  (without the `config:service:` prefix) and `value` is the new value
  (or `nil` for deletes).
  """

  use GenServer
  require Logger

  @type handler :: (String.t(), term() -> any())

  def start_link(opts) do
    service = Keyword.fetch!(opts, :service)
    name = Keyword.get(opts, :name, via_name(service))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  defp via_name(service) when is_atom(service), do: :"#{__MODULE__}.#{service}"

  @resubscribe_delay_ms 1_000

  @impl true
  def init(opts) do
    service = Keyword.fetch!(opts, :service)
    handler = Keyword.fetch!(opts, :handler)
    prefix = "config:#{service}:"
    pattern = "config:#{service}:*"

    state = %{
      service: service,
      handler: handler,
      prefix: prefix,
      pattern: pattern,
      subscription_ref: nil,
      bridge_monitor: nil
    }

    {:ok, subscribe_to_bridge(state)}
  end

  @impl true
  def handle_info({:store_event, %{type: type, key: key, value: value}}, state) do
    if String.starts_with?(key, state.prefix) do
      config_key = String.trim_leading(key, state.prefix)

      Logger.debug("ConfigWatcher[#{state.service}]: #{type} #{config_key}")

      try do
        state.handler.(config_key, if(type == :delete, do: nil, else: value))
      rescue
        e ->
          Logger.warning(
            "ConfigWatcher[#{state.service}]: handler error for #{config_key}: #{inspect(e)}"
          )
      end
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
    case YellowDog.Store.EventBridge.subscribe(state.pattern) do
      {:ok, ref} ->
        case Process.whereis(YellowDog.Store.EventBridge) do
          pid when is_pid(pid) ->
            mon = Process.monitor(pid)
            %{state | subscription_ref: ref, bridge_monitor: mon}

          nil ->
            %{state | subscription_ref: ref, bridge_monitor: nil}
        end

      _ ->
        Logger.warning("ConfigWatcher[#{state.service}]: failed to subscribe, retrying")
        Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
        state
    end
  rescue
    e ->
      Logger.warning("ConfigWatcher[#{state.service}]: subscribe error: #{inspect(e)}")
      Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
      state
  end
end
