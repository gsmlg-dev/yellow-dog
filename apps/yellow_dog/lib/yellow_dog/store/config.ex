defmodule YellowDog.Store.Config do
  @moduledoc """
  Runtime configuration overrides backed by Concord.

  Provides a thin overlay on top of the TOML-based config.
  Values written here take precedence; deleting a key causes
  the system to fall back to the TOML default.

  Writes emit events via EventBridge so ConfigWatcher can react.
  """

  alias YellowDog.Store.Key

  @namespace :config

  @spec get(atom(), atom() | String.t(), term()) :: term()
  def get(service, key, default \\ nil) when is_atom(service) do
    concord_key = Key.config(service, key)

    timed(:get, concord_key, fn ->
      case Concord.get(concord_key, consistency: :leader) do
        {:ok, value} -> value
        {:error, :not_found} -> default
        {:error, _} -> default
      end
    end)
  end

  @spec put(atom(), atom() | String.t(), term()) :: :ok | {:error, term()}
  def put(service, key, value) when is_atom(service) do
    concord_key = Key.config(service, key)

    timed(:put, concord_key, fn ->
      result = Concord.put(concord_key, value, consistency: :strong)

      if result == :ok do
        YellowDog.Store.EventBridge.notify(:put, concord_key, value)
      end

      result
    end)
  end

  @spec list(atom()) :: {:ok, [{String.t(), term()}]}
  def list(service) when is_atom(service) do
    prefix = Key.config_prefix(service)

    timed(:list, prefix, fn ->
      Concord.prefix_scan(prefix, [])
    end)
  end

  @spec delete(atom(), atom() | String.t()) :: :ok | {:error, term()}
  def delete(service, key) when is_atom(service) do
    concord_key = Key.config(service, key)

    timed(:delete, concord_key, fn ->
      result = Concord.delete(concord_key)

      if result == :ok do
        YellowDog.Store.EventBridge.notify(:delete, concord_key, nil)
      end

      result
    end)
  end

  defp timed(operation, key, fun) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start

    YellowDog.Store.emit_telemetry(@namespace, operation, key, duration)

    result
  end
end
