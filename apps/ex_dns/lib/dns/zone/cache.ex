defmodule DNS.Zone.Cache do
  @moduledoc """
  Zone caching system for DNS zones.

  Provides in-memory caching for zone data with TTL-based expiration,
  automatic refresh, and memory management.
  """

  alias DNS.Zone
  alias DNS.Zone.Name

  @cache_table :dns_zone_cache
  @meta_table :dns_zone_cache_meta
  @ets_options [:named_table, :public, :set, read_concurrency: true]

  @doc """
  Initialize the zone cache.
  """
  @spec init() :: :ok
  def init() do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, @ets_options)
    end

    if :ets.whereis(@meta_table) == :undefined do
      :ets.new(@meta_table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc """
  Store a zone in cache with TTL.
  """
  @spec put_zone(Zone.t(), integer(), keyword()) :: :ok
  def put_zone(zone, ttl_seconds \\ 300, options \\ []) do
    init()

    key = normalize_zone_key(zone.name)
    expires_at = System.system_time(:second) + ttl_seconds

    # Store zone data
    :ets.insert(@cache_table, {key, zone})

    # Store metadata
    :ets.insert(@meta_table, {
      key,
      %{
        ttl: ttl_seconds,
        expires_at: expires_at,
        last_updated: System.system_time(:second),
        refresh_interval: Keyword.get(options, :refresh_interval, ttl_seconds),
        source: Keyword.get(options, :source, :unknown)
      }
    })

    :ok
  end

  @doc """
  Get a zone from cache if not expired.
  """
  @spec get_zone(String.t() | Name.t()) :: {:ok, Zone.t()} | {:error, :not_found | :expired}
  def get_zone(name) do
    init()

    key = normalize_zone_key(name)

    case :ets.lookup(@cache_table, key) do
      [{^key, zone}] ->
        case :ets.lookup(@meta_table, key) do
          [{^key, meta}] ->
            now = System.system_time(:second)

            if meta.expires_at > now do
              {:ok, zone}
            else
              # Expired, remove from cache
              delete_zone(name)
              {:error, :expired}
            end

          [] ->
            # No metadata, treat as expired
            delete_zone(name)
            {:error, :expired}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Check if a zone is cached and not expired.
  """
  @spec zone_cached?(String.t() | Name.t()) :: boolean()
  def zone_cached?(name) do
    case get_zone(name) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Get cache metadata for a zone.
  """
  @spec get_zone_meta(String.t() | Name.t()) :: {:ok, map()} | {:error, :not_found}
  def get_zone_meta(name) do
    init()
    key = normalize_zone_key(name)

    case :ets.lookup(@meta_table, key) do
      [{^key, meta}] -> {:ok, meta}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Remove a zone from cache.
  """
  @spec delete_zone(String.t() | Name.t()) :: :ok
  def delete_zone(name) do
    init()
    key = normalize_zone_key(name)
    :ets.delete(@cache_table, key)
    :ets.delete(@meta_table, key)
    :ok
  end

  @doc """
  Clear the entire cache.
  """
  @spec clear() :: :ok
  def clear() do
    init()
    :ets.delete_all_objects(@cache_table)
    :ets.delete_all_objects(@meta_table)
    :ok
  end

  @doc """
  Get all cached zones that are not expired.
  """
  @spec list_zones() :: list({Zone.t(), map()})
  def list_zones() do
    init()
    now = System.system_time(:second)

    @cache_table
    |> :ets.tab2list()
    |> Enum.map(fn {key, zone} ->
      case :ets.lookup(@meta_table, key) do
        [{^key, meta}] ->
          if meta.expires_at > now do
            {zone, meta}
          else
            delete_zone(key)
            nil
          end

        [] ->
          delete_zone(key)
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {zone, _} -> zone.name.value end)
  end

  @doc """
  Clean expired zones from cache.
  """
  @spec cleanup_expired() :: integer()
  def cleanup_expired() do
    init()
    now = System.system_time(:second)

    expired_keys =
      @meta_table
      |> :ets.tab2list()
      |> Enum.filter(fn {_key, meta} -> meta.expires_at <= now end)
      |> Enum.map(fn {key, _} -> key end)

    Enum.each(expired_keys, &delete_zone/1)
    length(expired_keys)
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats() do
    init()

    _now = System.system_time(:second)

    zones = list_zones()
    total_entries = length(:ets.tab2list(@cache_table))
    valid_entries = length(zones)
    expired_entries = total_entries - valid_entries

    %{
      total_entries: total_entries,
      valid_entries: valid_entries,
      expired_entries: expired_entries,
      cache_hit_ratio: calculate_hit_ratio(),
      memory_usage: :ets.info(@cache_table, :memory)
    }
  end

  @doc """
  Refresh a zone from its source if needed.
  """
  @spec refresh_zone(String.t() | Name.t()) :: {:ok, Zone.t()} | {:error, String.t()}
  def refresh_zone(name) do
    case get_zone_meta(name) do
      {:ok, meta} ->
        now = System.system_time(:second)

        if now >= meta.expires_at - meta.refresh_interval do
          # TODO: Implement actual refresh logic based on source
          {:ok, "refresh_not_implemented"}
        else
          {:error, "not_due_for_refresh"}
        end

      {:error, _} = error ->
        error
    end
  end

  ## Private functions

  defp normalize_zone_key(name) when is_binary(name) do
    String.downcase(name)
  end

  defp normalize_zone_key(%Name{value: value}) do
    String.downcase(value)
  end

  defp calculate_hit_ratio() do
    # TODO: Implement hit ratio calculation based on lookup stats
    0.0
  end
end
