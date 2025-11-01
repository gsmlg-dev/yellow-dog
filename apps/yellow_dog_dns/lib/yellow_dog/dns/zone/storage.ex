defmodule YellowDog.Dns.Zone.Storage do
  @moduledoc """
  ETS-based storage for DNS zones and records.

  Provides high-performance, concurrent storage for DNS zones with the following tables:
  - `:zone_data` - Main record storage with read_concurrency
  - `:zone_metadata` - Zone metadata (serial, type, etc.)
  - `:zone_index` - Index for fast zone lookups

  ## Storage Schema

  ### zone_data table
  Key: {zone_name, owner, record_type}
  Value: %{rdata: ..., ttl: ..., class: :IN}

  ### zone_metadata table
  Key: zone_name
  Value: %{type: :master, file: "...", serial: ..., loaded_at: ...}

  ### zone_index table
  Key: zone_name
  Value: %{records_count: ..., last_modified: ...}
  """

  require Logger

  @zone_data_table :dns_zone_data
  @zone_metadata_table :dns_zone_metadata
  @zone_index_table :dns_zone_index

  @doc """
  Initializes the ETS tables for zone storage.

  Creates three tables with appropriate concurrency settings:
  - zone_data: set with read_concurrency for fast lookups
  - zone_metadata: set for zone information
  - zone_index: set for zone indexing

  ## Returns
  - `:ok` - Tables created successfully
  - `{:error, :already_exists}` - Tables already exist

  ## Examples

      iex> YellowDog.Dns.Zone.Storage.init()
      :ok

      iex> YellowDog.Dns.Zone.Storage.init()
      {:error, :already_exists}
  """
  @spec init() :: :ok | {:error, :already_exists}
  def init do
    case create_tables() do
      :ok ->
        Logger.info("DNS zone storage initialized successfully")
        :ok

      {:error, reason} = error ->
        Logger.warning("DNS zone storage initialization failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Inserts a DNS record into zone storage.

  ## Parameters
  - `zone_name` - The zone name (e.g., "example.com")
  - `owner` - Record owner/name (e.g., "www", "@")
  - `record_type` - Record type atom (e.g., :A, :AAAA, :MX)
  - `rdata` - Record data (format depends on type)
  - `ttl` - Time to live in seconds (default: 3600)
  - `class` - DNS class (default: :IN)

  ## Examples

      iex> Storage.insert_record("example.com", "www", :A, {192, 168, 1, 10}, 300)
      :ok

      iex> Storage.insert_record("example.com", "@", :MX, {10, "mail.example.com"}, 600)
      :ok
  """
  @spec insert_record(String.t(), String.t(), atom(), any(), non_neg_integer(), atom()) :: :ok
  def insert_record(zone_name, owner, record_type, rdata, ttl \\ 3600, class \\ :IN) do
    key = {normalize_zone(zone_name), normalize_owner(owner), record_type}

    value = %{
      rdata: rdata,
      ttl: ttl,
      class: class,
      inserted_at: System.system_time(:second)
    }

    :ets.insert(@zone_data_table, {key, value})

    # Update zone index
    update_zone_index(zone_name, :insert)

    :telemetry.execute([:yellow_dog, :dns, :zone, :record_inserted], %{ttl: ttl}, %{
      zone: zone_name,
      owner: owner,
      type: record_type
    })

    :ok
  end

  @doc """
  Looks up DNS records in zone storage.

  ## Parameters
  - `zone_name` - The zone name
  - `owner` - Record owner/name
  - `record_type` - Record type atom

  ## Returns
  - `{:ok, [records]}` - List of matching records
  - `{:error, :not_found}` - No records found

  ## Examples

      iex> Storage.lookup_record("example.com", "www", :A)
      {:ok, [%{rdata: {192, 168, 1, 10}, ttl: 300, class: :IN}]}

      iex> Storage.lookup_record("example.com", "notexist", :A)
      {:error, :not_found}
  """
  @spec lookup_record(String.t(), String.t(), atom()) ::
          {:ok, [map()]} | {:error, :not_found}
  def lookup_record(zone_name, owner, record_type) do
    key = {normalize_zone(zone_name), normalize_owner(owner), record_type}

    case :ets.lookup(@zone_data_table, key) do
      [{^key, record}] ->
        {:ok, [record]}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes a DNS record from zone storage.

  ## Parameters
  - `zone_name` - The zone name
  - `owner` - Record owner/name
  - `record_type` - Record type atom

  ## Returns
  - `:ok` - Record deleted successfully
  """
  @spec delete_record(String.t(), String.t(), atom()) :: :ok
  def delete_record(zone_name, owner, record_type) do
    key = {normalize_zone(zone_name), normalize_owner(owner), record_type}
    :ets.delete(@zone_data_table, key)

    # Update zone index
    update_zone_index(zone_name, :delete)

    :telemetry.execute([:yellow_dog, :dns, :zone, :record_deleted], %{}, %{
      zone: zone_name,
      owner: owner,
      type: record_type
    })

    :ok
  end

  @doc """
  Lists all records for a given zone.

  ## Parameters
  - `zone_name` - The zone name

  ## Returns
  - `{:ok, records}` - List of all records in the zone
  """
  @spec list_zone_records(String.t()) :: {:ok, [map()]}
  def list_zone_records(zone_name) do
    normalized_zone = normalize_zone(zone_name)

    records =
      :ets.select(@zone_data_table, [
        {
          {
            {:"$1", :"$2", :"$3"},
            :"$4"
          },
          [{:==, :"$1", normalized_zone}],
          [{{:"$2", :"$3", :"$4"}}]
        }
      ])

    {:ok,
     Enum.map(records, fn {owner, type, data} ->
       Map.put(data, :owner, owner) |> Map.put(:type, type)
     end)}
  end

  @doc """
  Deletes all records for a zone.

  ## Parameters
  - `zone_name` - The zone name

  ## Returns
  - `:ok` - All records deleted
  """
  @spec delete_zone(String.t()) :: :ok
  def delete_zone(zone_name) do
    normalized_zone = normalize_zone(zone_name)

    # Delete all records for this zone
    :ets.select_delete(@zone_data_table, [
      {
        {{:"$1", :_, :_}, :_},
        [{:==, :"$1", normalized_zone}],
        [true]
      }
    ])

    # Delete zone metadata
    :ets.delete(@zone_metadata_table, normalized_zone)

    # Delete zone index
    :ets.delete(@zone_index_table, normalized_zone)

    :telemetry.execute([:yellow_dog, :dns, :zone, :deleted], %{}, %{zone: zone_name})

    Logger.info("Zone deleted", zone: zone_name)
    :ok
  end

  @doc """
  Stores zone metadata.

  ## Parameters
  - `zone_name` - The zone name
  - `metadata` - Map containing zone metadata

  ## Examples

      iex> Storage.put_zone_metadata("example.com", %{
      ...>   type: :master,
      ...>   file: "zones/example.com.zone",
      ...>   serial: 2024102801,
      ...>   loaded_at: System.system_time(:second)
      ...> })
      :ok
  """
  @spec put_zone_metadata(String.t(), map()) :: :ok
  def put_zone_metadata(zone_name, metadata) do
    normalized_zone = normalize_zone(zone_name)
    :ets.insert(@zone_metadata_table, {normalized_zone, metadata})
    :ok
  end

  @doc """
  Retrieves zone metadata.

  ## Parameters
  - `zone_name` - The zone name

  ## Returns
  - `{:ok, metadata}` - Zone metadata map
  - `{:error, :not_found}` - Zone not found
  """
  @spec get_zone_metadata(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_zone_metadata(zone_name) do
    normalized_zone = normalize_zone(zone_name)

    case :ets.lookup(@zone_metadata_table, normalized_zone) do
      [{^normalized_zone, metadata}] ->
        {:ok, metadata}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists all loaded zones.

  ## Returns
  - `{:ok, [zone_names]}` - List of zone names
  """
  @spec list_zones() :: {:ok, [String.t()]}
  def list_zones do
    zones =
      :ets.select(@zone_metadata_table, [
        {
          {:"$1", :_},
          [],
          [:"$1"]
        }
      ])

    {:ok, zones}
  end

  @doc """
  Checks if a zone exists in storage.

  ## Parameters
  - `zone_name` - The zone name

  ## Returns
  - `true` - Zone exists
  - `false` - Zone does not exist
  """
  @spec zone_exists?(String.t()) :: boolean()
  def zone_exists?(zone_name) do
    normalized_zone = normalize_zone(zone_name)
    :ets.member(@zone_metadata_table, normalized_zone)
  end

  @doc """
  Gets statistics for a zone.

  ## Parameters
  - `zone_name` - The zone name

  ## Returns
  - `{:ok, stats}` - Zone statistics
  - `{:error, :not_found}` - Zone not found
  """
  @spec get_zone_stats(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_zone_stats(zone_name) do
    case get_zone_metadata(zone_name) do
      {:ok, metadata} ->
        normalized_zone = normalize_zone(zone_name)

        # Count records
        record_count =
          :ets.select_count(@zone_data_table, [
            {
              {{:"$1", :_, :_}, :_},
              [{:==, :"$1", normalized_zone}],
              [true]
            }
          ])

        stats = %{
          zone: zone_name,
          type: Map.get(metadata, :type),
          serial: Map.get(metadata, :serial),
          record_count: record_count,
          loaded_at: Map.get(metadata, :loaded_at)
        }

        {:ok, stats}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Gets global storage statistics.

  ## Returns
  - Map with storage statistics
  """
  @spec stats() :: map()
  def stats do
    {:ok, zones} = list_zones()
    total_zones = length(zones)

    total_records = :ets.info(@zone_data_table, :size)

    memory_words = :ets.info(@zone_data_table, :memory)
    memory_bytes = memory_words * :erlang.system_info(:wordsize)

    %{
      total_zones: total_zones,
      total_records: total_records,
      memory_bytes: memory_bytes,
      memory_mb: Float.round(memory_bytes / 1024 / 1024, 2)
    }
  end

  # Private functions

  defp create_tables do
    tables = [
      {@zone_data_table, [:set, :public, :named_table, read_concurrency: true]},
      {@zone_metadata_table, [:set, :public, :named_table]},
      {@zone_index_table, [:set, :public, :named_table]}
    ]

    Enum.reduce_while(tables, :ok, fn {name, opts}, _acc ->
      case :ets.whereis(name) do
        :undefined ->
          :ets.new(name, opts)
          {:cont, :ok}

        _tid ->
          {:halt, {:error, :already_exists}}
      end
    end)
  end

  defp normalize_zone(zone_name) when is_binary(zone_name) do
    zone_name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp normalize_owner("@"), do: "@"
  defp normalize_owner(owner) when is_binary(owner), do: String.downcase(owner)

  defp update_zone_index(zone_name, operation) do
    normalized_zone = normalize_zone(zone_name)

    case :ets.lookup(@zone_index_table, normalized_zone) do
      [{^normalized_zone, index}] ->
        count = Map.get(index, :records_count, 0)

        new_count =
          case operation do
            :insert -> count + 1
            :delete -> max(0, count - 1)
          end

        new_index =
          index
          |> Map.put(:records_count, new_count)
          |> Map.put(:last_modified, System.system_time(:second))

        :ets.insert(@zone_index_table, {normalized_zone, new_index})

      [] ->
        index = %{
          records_count: 1,
          last_modified: System.system_time(:second)
        }

        :ets.insert(@zone_index_table, {normalized_zone, index})
    end

    :ok
  end
end
