defmodule YellowDog.Store.Provider do
  @moduledoc """
  DNS provider data facade over the Store backend.

  Manages provider configuration, sync status, and conflict records.
  Write-through: Concord persist then ETS cache; reads from ETS only.

  Key patterns (via `YellowDog.Store.Key`):
  - Config: `dns:provider:{name}:config`
  - Status: `dns:provider:{name}:status`
  - Conflicts: `dns:provider:{name}:conflict:{id}`
  """

  alias YellowDog.Store.{Backend, EventBridge, Key}

  # -------------------------------------------------------------------
  # Config
  # -------------------------------------------------------------------

  @spec put_config(map()) :: :ok | {:error, term()}
  def put_config(%{name: name} = config) do
    key = Key.provider_config(name)
    start_time = System.monotonic_time()

    case Backend.active().put(key, config, []) do
      :ok ->
        emit_telemetry(start_time, :provider, :put, key)
        EventBridge.notify(:put, key, config)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @spec get_config(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_config(name) do
    key = Key.provider_config(name)
    Backend.active().get(key, [])
  end

  @spec list_configs() :: {:ok, [map()]}
  def list_configs do
    prefix = Key.provider_prefix()

    case Backend.active().prefix_scan(prefix, []) do
      {:ok, entries} ->
        configs =
          entries
          |> Enum.filter(fn {key, _v} -> String.ends_with?(key, ":config") end)
          |> Enum.map(fn {_key, value} -> value end)

        {:ok, configs}

      {:error, _} ->
        {:ok, []}
    end
  end

  @spec delete_config(String.t()) :: :ok | {:error, term()}
  def delete_config(name) do
    key = Key.provider_config(name)
    start_time = System.monotonic_time()

    case Backend.active().delete(key) do
      :ok ->
        emit_telemetry(start_time, :provider, :delete, key)
        EventBridge.notify(:delete, key, nil)
        :ok

      {:error, _} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Status
  # -------------------------------------------------------------------

  @spec put_status(String.t(), map()) :: :ok | {:error, term()}
  def put_status(name, status) do
    key = Key.provider_status(name)
    Backend.active().put(key, status, [])
  end

  @spec get_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_status(name) do
    key = Key.provider_status(name)
    Backend.active().get(key, [])
  end

  # -------------------------------------------------------------------
  # Conflicts
  # -------------------------------------------------------------------

  @spec put_conflict(map()) :: :ok | {:error, term()}
  def put_conflict(%{provider_name: name, id: id} = conflict) do
    key = Key.provider_conflict(name, id)
    Backend.active().put(key, conflict, [])
  end

  @spec list_conflicts(String.t()) :: {:ok, [map()]}
  def list_conflicts(name) do
    prefix = Key.provider_conflict_prefix(name)

    case Backend.active().prefix_scan(prefix, []) do
      {:ok, entries} -> {:ok, Enum.map(entries, fn {_k, v} -> v end)}
      {:error, _} -> {:ok, []}
    end
  end

  @spec delete_conflict(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_conflict(name, conflict_id) do
    key = Key.provider_conflict(name, conflict_id)
    Backend.active().delete(key)
  end

  # -------------------------------------------------------------------
  # Telemetry
  # -------------------------------------------------------------------

  defp emit_telemetry(start_time, namespace, operation, key) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:yellow_dog, :store, :operation, :stop],
      %{duration: duration},
      %{namespace: namespace, operation: operation, key: key, consistency: :strong}
    )
  end
end
