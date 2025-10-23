defmodule DNS.Zone.Store do
  @moduledoc """
  Zone storage system for managing DNS zones in memory.

  Provides ETS-based storage for zone management with optional persistence.
  """

  alias DNS.Zone
  alias DNS.Zone.Name

  @table_name :dns_zones
  @ets_options [:named_table, :public, :set, read_concurrency: true]

  @doc """
  Initialize the zone store.
  """
  @spec init() :: :ok
  def init() do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, @ets_options)
    end

    :ok
  end

  @doc """
  Ensure the zone store is initialized.
  """
  @spec ensure_initialized() :: :ok
  def ensure_initialized() do
    init()
  end

  @doc """
  Store a zone.
  """
  @spec put_zone(Zone.t()) :: {:ok, Zone.t()}
  def put_zone(zone) do
    ensure_initialized()
    key = normalize_zone_key(zone.name)
    :ets.insert(@table_name, {key, zone})
    {:ok, zone}
  end

  @doc """
  Get a zone by name.
  """
  @spec get_zone(String.t() | Name.t()) :: {:ok, Zone.t()} | {:error, :not_found}
  def get_zone(name) do
    ensure_initialized()
    key = normalize_zone_key(name)

    case :ets.lookup(@table_name, key) do
      [{^key, zone}] -> {:ok, zone}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  List all zones.
  """
  @spec list_zones() :: list(Zone.t())
  def list_zones() do
    ensure_initialized()

    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_key, zone} -> zone end)
    |> Enum.sort_by(& &1.name.value)
  end

  @doc """
  Delete a zone.
  """
  @spec delete_zone(String.t() | Name.t()) :: :ok
  def delete_zone(name) do
    ensure_initialized()
    key = normalize_zone_key(name)
    :ets.delete(@table_name, key)
    :ok
  end

  @doc """
  Check if a zone exists.
  """
  @spec zone_exists?(String.t() | Name.t()) :: boolean()
  def zone_exists?(name) do
    ensure_initialized()
    key = normalize_zone_key(name)

    case :ets.lookup(@table_name, key) do
      [{^key, _zone}] -> true
      [] -> false
    end
  end

  @doc """
  Get zones by type.
  """
  @spec get_zones_by_type(Zone.zone_type()) :: list(Zone.t())
  def get_zones_by_type(type) do
    ensure_initialized()

    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_key, zone} -> zone end)
    |> Enum.filter(&(&1.type == type))
  end

  @doc """
  Clear all zones.
  """
  @spec clear() :: :ok
  def clear() do
    init()
    :ets.delete_all_objects(@table_name)
    :ok
  end

  ## Private functions

  defp normalize_zone_key(name) when is_binary(name) do
    String.downcase(name)
  end

  defp normalize_zone_key(%Name{value: value}) do
    String.downcase(value)
  end
end
