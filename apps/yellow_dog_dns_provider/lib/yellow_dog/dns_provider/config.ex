defmodule YellowDog.DnsProvider.Config do
  @moduledoc """
  Configuration struct for a DNS zone provider.

  Persisted to Concord via `Store.Provider`. Created/updated through
  the console UI or the `YellowDog.DnsProvider` public API.
  """

  @valid_types [:iana_root, :aws, :cloudflare, :gcp, :vultr]
  @valid_strategies [:local_wins, :remote_wins, :manual]

  @enforce_keys [:name, :type, :zones]
  defstruct [
    :name,
    :type,
    :credentials,
    zones: [],
    sync_interval: 300,
    conflict_strategy: :local_wins,
    enabled: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          type: atom(),
          credentials: map() | nil,
          zones: [String.t()],
          sync_interval: pos_integer(),
          conflict_strategy: :local_wins | :remote_wins | :manual,
          enabled: boolean()
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- require_string(attrs, :name),
         {:ok, type} <- validate_type(attrs),
         {:ok, strategy} <- validate_strategy(attrs) do
      {:ok,
       %__MODULE__{
         name: name,
         type: type,
         credentials: Map.get(attrs, :credentials),
         zones: Map.get(attrs, :zones, []),
         sync_interval: Map.get(attrs, :sync_interval, 300),
         conflict_strategy: strategy,
         enabled: Map.get(attrs, :enabled, true)
       }}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    Map.from_struct(config)
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, atom()}
  def from_map(map) when is_map(map) do
    new(map)
  end

  defp require_string(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:error, :"missing_#{key}"}
      val when is_binary(val) -> {:ok, val}
      val when is_atom(val) -> {:ok, to_string(val)}
    end
  end

  defp validate_type(attrs) do
    case Map.get(attrs, :type) do
      nil -> {:error, :missing_type}
      type when type in @valid_types -> {:ok, type}
      _ -> {:error, :invalid_type}
    end
  end

  defp validate_strategy(attrs) do
    case Map.get(attrs, :conflict_strategy, :local_wins) do
      s when s in @valid_strategies -> {:ok, s}
      _ -> {:error, :invalid_conflict_strategy}
    end
  end
end
