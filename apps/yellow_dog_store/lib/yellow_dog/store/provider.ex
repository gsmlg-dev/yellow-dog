defmodule YellowDog.Store.Provider do
  @moduledoc """
  Store facade for DNS provider connector configurations.

  Provider configs are Store-backed connector records used by the console and
  future DNS sync workers. Secrets are stored inside the connector config map;
  callers are responsible for masking them when rendering.
  """

  alias YellowDog.Store.{Backend, EventBridge, Key}
  alias YellowDog.Store.Backend.Ets, as: EtsBackend

  @valid_types [:cloudflare, :route53]

  @type provider_type :: :cloudflare | :route53
  @type config :: %{
          name: String.t(),
          type: provider_type(),
          credentials: map(),
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

    case Backend.active().delete(key) do
      :ok ->
        EventBridge.notify(:delete, key, nil)
        :ok

      {:error, _} = error ->
        error
    end
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
end
