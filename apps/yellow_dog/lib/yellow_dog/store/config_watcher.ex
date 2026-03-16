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

  defp via_name(service), do: :"#{__MODULE__}.#{service}"

  @impl true
  def init(opts) do
    service = Keyword.fetch!(opts, :service)
    handler = Keyword.fetch!(opts, :handler)
    prefix = "config:#{service}:"

    subscribe(prefix)

    {:ok, %{service: service, handler: handler, prefix: prefix}}
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

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp subscribe(prefix) do
    pattern = String.trim_trailing(prefix, ":") <> ":*"

    try do
      YellowDog.Store.EventBridge.subscribe(pattern)
    rescue
      e ->
        Logger.warning("ConfigWatcher: failed to subscribe: #{inspect(e)}")
    end
  end
end
