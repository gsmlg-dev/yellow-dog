defmodule YellowDog.Store.Provider do
  @moduledoc """
  DNS provider data facade over the Store backend.

  Stores cloud DNS connector configuration for the console mirror flow and
  provider sync status/conflicts for the DNS provider subsystem.
  """

  alias YellowDog.Store.{Backend, EventBridge, Key}
  alias YellowDog.Store.Backend.Ets, as: EtsBackend

  @valid_types [:cloudflare, :route53, :iana_root, :aws, :gcp, :vultr]

  @type provider_type :: :cloudflare | :route53 | :iana_root | :aws | :gcp | :vultr
  @type config :: %{
          name: String.t(),
          type: provider_type(),
          credentials: map() | nil,
          zones: [String.t()],
          enabled: boolean(),
          created_at: integer(),
          updated_at: integer()
        }

  @spec put_config(map()) :: :ok | {:error, term()}
  def put_config(%{name: name, type: type} = config)
      when is_binary(name) and type in @valid_types do
    ensure_ets_backend()

    name = String.trim(name)

    if name == "" do
      {:error, :invalid_name}
    else
      key = Key.provider_config(name)
      now = System.system_time(:second)
      start_time = System.monotonic_time()

      value =
        config
        |> Map.put(:name, name)
        |> Map.put(:type, type)
        |> Map.put_new(:credentials, %{})
        |> Map.put_new(:zones, [])
        |> Map.put_new(:enabled, true)
        |> put_timestamps(key, now)

      case Backend.active().put(key, value, consistency: :strong) do
        :ok ->
          emit_telemetry(start_time, :provider, :put, key)
          EventBridge.notify(:put, key, value)
          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  def put_config(%{type: type}) when type not in @valid_types, do: {:error, :unsupported_provider}
  def put_config(_config), do: {:error, :invalid_config}

  @spec get_config(String.t()) :: {:ok, config()} | {:error, :not_found | term()}
  def get_config(name) when is_binary(name) do
    ensure_ets_backend()
    Backend.active().get(Key.provider_config(String.trim(name)), consistency: :eventual)
  end

  @spec list_configs() :: {:ok, [config()]} | {:error, term()}
  def list_configs do
    ensure_ets_backend()

    with {:ok, entries} <- Backend.active().prefix_scan(Key.provider_config_prefix()) do
      configs =
        entries
        |> Enum.filter(fn {key, _value} -> String.ends_with?(key, ":config") end)
        |> Enum.map(fn {_key, value} -> value end)
        |> Enum.sort_by(& &1.name)

      {:ok, configs}
    end
  end

  @spec delete_config(String.t()) :: :ok | {:error, term()}
  def delete_config(name) when is_binary(name) do
    ensure_ets_backend()

    key = Key.provider_config(String.trim(name))
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

  @spec put_status(String.t(), map()) :: :ok | {:error, term()}
  def put_status(name, status) when is_binary(name) do
    ensure_ets_backend()
    Backend.active().put(Key.provider_status(String.trim(name)), status, consistency: :strong)
  end

  @spec get_status(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_status(name) when is_binary(name) do
    ensure_ets_backend()
    Backend.active().get(Key.provider_status(String.trim(name)), consistency: :eventual)
  end

  @spec put_conflict(map()) :: :ok | {:error, term()}
  def put_conflict(%{provider_name: name, id: id} = conflict)
      when is_binary(name) and is_binary(id) do
    ensure_ets_backend()
    Backend.active().put(Key.provider_conflict(name, id), conflict, consistency: :strong)
  end

  @spec list_conflicts(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_conflicts(name) when is_binary(name) do
    ensure_ets_backend()

    with {:ok, entries} <- Backend.active().prefix_scan(Key.provider_conflict_prefix(name)) do
      {:ok, Enum.map(entries, fn {_key, value} -> value end)}
    end
  end

  @spec delete_conflict(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_conflict(name, conflict_id) when is_binary(name) and is_binary(conflict_id) do
    ensure_ets_backend()
    Backend.active().delete(Key.provider_conflict(name, conflict_id))
  end

  defp put_timestamps(config, key, now) do
    created_at =
      case Backend.active().get(key, consistency: :strong) do
        {:ok, existing} -> Map.get(existing, :created_at, now)
        _ -> now
      end

    config
    |> Map.put(:created_at, created_at)
    |> Map.put(:updated_at, now)
  end

  defp ensure_ets_backend do
    if Backend.active() == EtsBackend do
      EtsBackend.create_table()
    end
  end

  defp emit_telemetry(start_time, namespace, operation, key) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:yellow_dog, :store, :operation, :stop],
      %{duration: duration},
      %{namespace: namespace, operation: operation, key: key, consistency: :strong}
    )
  end
end
