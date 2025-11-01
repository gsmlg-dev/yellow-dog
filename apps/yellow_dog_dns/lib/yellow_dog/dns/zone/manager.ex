defmodule YellowDog.Dns.Zone.Manager do
  @moduledoc """
  GenServer for managing DNS zone lifecycle.

  Handles:
  - Loading zones from files or memory
  - Unloading zones
  - Reloading zones
  - Zone state management
  - Integration with Zone.Storage

  ## Usage

      # Load a zone from file
      {:ok, _} = Zone.Manager.load_zone("example.com", file: "zones/example.com.zone")

      # Load a zone from struct
      zone = Zone.new("example.com", :master)
      {:ok, _} = Zone.Manager.load_zone_data("example.com", zone)

      # Reload a zone
      :ok = Zone.Manager.reload_zone("example.com")

      # Unload a zone
      :ok = Zone.Manager.unload_zone("example.com")

      # List all zones
      {:ok, zones} = Zone.Manager.list_zones()
  """

  use GenServer
  require Logger

  alias YellowDog.Dns.Zone
  alias YellowDog.Dns.Zone.Storage
  alias YellowDog.Dns.Zone.Forward
  alias YellowDog.Telemetry

  @type load_opts :: [
          file: String.t(),
          type: Zone.zone_type(),
          ttl: non_neg_integer()
        ]

  ## Client API

  @doc """
  Starts the Zone Manager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Loads a zone from a file or configuration.

  ## Parameters
  - `zone_name` - The zone name (e.g., "example.com")
  - `opts` - Load options

  ## Options
  - `:file` - Path to zone file (required if no :data)
  - `:type` - Zone type (default: :master)
  - `:ttl` - Default TTL (default: 3600)

  ## Returns
  - `{:ok, zone_name}` - Zone loaded successfully
  - `{:error, reason}` - Failed to load zone

  ## Examples

      iex> Zone.Manager.load_zone("example.com", file: "zones/example.com.zone")
      {:ok, "example.com"}

      iex> Zone.Manager.load_zone("example.com", file: "nonexistent.zone")
      {:error, :file_not_found}
  """
  @spec load_zone(String.t(), load_opts()) :: {:ok, String.t()} | {:error, any()}
  def load_zone(zone_name, opts) do
    GenServer.call(__MODULE__, {:load_zone, zone_name, opts}, :timer.seconds(30))
  end

  @doc """
  Loads a zone from a Zone struct.

  ## Parameters
  - `zone_name` - The zone name
  - `zone` - Zone struct with records

  ## Returns
  - `{:ok, zone_name}` - Zone loaded successfully
  - `{:error, reason}` - Failed to load zone
  """
  @spec load_zone_data(String.t(), Zone.t()) :: {:ok, String.t()} | {:error, any()}
  def load_zone_data(zone_name, %Zone{} = zone) do
    GenServer.call(__MODULE__, {:load_zone_data, zone_name, zone})
  end

  @doc """
  Unloads a zone from memory.

  ## Parameters
  - `zone_name` - The zone name

  ## Returns
  - `:ok` - Zone unloaded successfully
  - `{:error, :not_found}` - Zone not loaded
  """
  @spec unload_zone(String.t()) :: :ok | {:error, :not_found}
  def unload_zone(zone_name) do
    GenServer.call(__MODULE__, {:unload_zone, zone_name})
  end

  @doc """
  Reloads a zone from its source.

  ## Parameters
  - `zone_name` - The zone name

  ## Returns
  - `:ok` - Zone reloaded successfully
  - `{:error, reason}` - Failed to reload
  """
  @spec reload_zone(String.t()) :: :ok | {:error, any()}
  def reload_zone(zone_name) do
    GenServer.call(__MODULE__, {:reload_zone, zone_name}, :timer.seconds(30))
  end

  @doc """
  Lists all loaded zones.

  ## Returns
  - `{:ok, [zone_names]}` - List of zone names
  """
  @spec list_zones() :: {:ok, [String.t()]}
  def list_zones do
    Storage.list_zones()
  end

  @doc """
  Gets metadata for a specific zone.

  ## Parameters
  - `zone_name` - The zone name

  ## Returns
  - `{:ok, metadata}` - Zone metadata map
  - `{:error, :not_found}` - Zone not found
  """
  @spec get_zone_metadata(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_zone_metadata(zone_name) do
    Storage.get_zone_metadata(zone_name)
  end

  @doc """
  Loads a forward zone with upstream forwarders.

  ## Parameters
  - `zone_name` - The zone name (e.g., "external.com")
  - `forwarders` - List of IP addresses to forward to
  - `opts` - Forward zone options

  ## Options
  - `:forward_mode` - Forward mode (:first or :only, default: :only)
  - `:timeout_ms` - Timeout in milliseconds (default: 5000)
  - `:max_retries` - Maximum retry attempts (default: 2)

  ## Returns
  - `{:ok, zone_name}` - Forward zone loaded successfully
  - `{:error, reason}` - Failed to load forward zone

  ## Examples

      iex> forwarders = [{8, 8, 8, 8}, {1, 1, 1, 1}]
      iex> Zone.Manager.load_forward_zone("external.com", forwarders, forward_mode: :only)
      {:ok, "external.com"}
  """
  @spec load_forward_zone(String.t(), [:inet.ip_address()], keyword()) ::
          {:ok, String.t()} | {:error, any()}
  def load_forward_zone(zone_name, forwarders, opts \\ []) do
    GenServer.call(__MODULE__, {:load_forward_zone, zone_name, forwarders, opts})
  end

  @doc """
  Gets statistics for all zones or a specific zone.

  ## Parameters
  - `zone_name` - Optional zone name

  ## Returns
  - Map with zone statistics
  """
  @spec stats(String.t() | nil) :: {:ok, map()} | {:error, any()}
  def stats(zone_name \\ nil) do
    GenServer.call(__MODULE__, {:stats, zone_name})
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Initialize storage
    case Storage.init() do
      :ok ->
        Logger.info("DNS Zone Manager started successfully")

        state = %{
          zones: %{},
          load_queue: []
        }

        {:ok, state}

      {:error, :already_exists} ->
        # Storage already initialized, continue
        Logger.info("DNS Zone Manager started (storage already initialized)")
        {:ok, %{zones: %{}, load_queue: []}}

      {:error, reason} ->
        Logger.error("Failed to initialize DNS Zone Manager: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:load_zone, zone_name, opts}, _from, state) do
    span_id = Telemetry.start_span("dns.zone.load", %{zone: zone_name})
    result = do_load_zone(zone_name, opts)

    case result do
      {:ok, _} = success ->
        # Store zone info in state
        zone_info = %{
          name: zone_name,
          file: Keyword.get(opts, :file),
          type: Keyword.get(opts, :type, :master),
          loaded_at: System.system_time(:second)
        }

        new_state = put_in(state, [:zones, zone_name], zone_info)
        Telemetry.end_span(span_id, %{status: :success, record_count: count_zone_records(zone_name)})
        {:reply, success, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to load zone #{zone_name}: #{inspect(reason)}")
        Telemetry.end_span(span_id, %{status: :failed, reason: reason})
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:load_zone_data, zone_name, zone}, _from, state) do
    result = do_load_zone_struct(zone_name, zone)

    case result do
      {:ok, _} = success ->
        zone_info = %{
          name: zone_name,
          type: zone.type,
          loaded_at: System.system_time(:second),
          source: :memory
        }

        new_state = put_in(state, [:zones, zone_name], zone_info)
        {:reply, success, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:load_forward_zone, zone_name, forwarders, opts}, _from, state) do
    # Create forward zone configuration
    forward = Forward.new(zone_name, forwarders, opts)

    case Forward.validate(forward) do
      :ok ->
        # Store forward zone metadata in storage
        metadata = Forward.to_storage_metadata(forward)
        Storage.put_zone_metadata(zone_name, metadata)

        # Track in state
        zone_info = %{
          name: zone_name,
          type: :forward,
          loaded_at: System.system_time(:second),
          source: :forward,
          forwarders: forwarders,
          forward_mode: forward.forward_mode
        }

        new_state = put_in(state, [:zones, zone_name], zone_info)

        Logger.info("Forward zone loaded",
          zone: zone_name,
          forwarders: length(forwarders),
          mode: forward.forward_mode
        )

        {:reply, {:ok, zone_name}, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to load forward zone #{zone_name}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:unload_zone, zone_name}, _from, state) do
    if Map.has_key?(state.zones, zone_name) do
      Storage.delete_zone(zone_name)

      new_state = %{state | zones: Map.delete(state.zones, zone_name)}

      Logger.info("Zone unloaded", zone: zone_name)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:reload_zone, zone_name}, _from, state) do
    case Map.get(state.zones, zone_name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      zone_info ->
        # Unload existing zone
        Storage.delete_zone(zone_name)

        # Reload from file if available
        case zone_info.file do
          nil ->
            {:reply, {:error, :no_source_file}, state}

          file ->
            opts = [
              file: file,
              type: zone_info.type
            ]

            case do_load_zone(zone_name, opts) do
              {:ok, _} = success ->
                # Update loaded_at timestamp
                updated_info = Map.put(zone_info, :loaded_at, System.system_time(:second))
                new_state = put_in(state, [:zones, zone_name], updated_info)

                Logger.info("Zone reloaded", zone: zone_name)
                {:reply, success, new_state}

              {:error, _} = error ->
                {:reply, error, state}
            end
        end
    end
  end

  @impl true
  def handle_call({:stats, nil}, _from, state) do
    # Global stats
    storage_stats = Storage.stats()

    stats = %{
      loaded_zones: map_size(state.zones),
      total_zones: storage_stats.total_zones,
      total_records: storage_stats.total_records,
      memory_mb: storage_stats.memory_mb
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_call({:stats, zone_name}, _from, state) do
    case Storage.get_zone_stats(zone_name) do
      {:ok, stats} -> {:reply, {:ok, stats}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  ## Private Functions

  defp do_load_zone(zone_name, opts) do
    file = Keyword.get(opts, :file)
    zone_type = Keyword.get(opts, :type, :master)
    ttl = Keyword.get(opts, :ttl, 3600)

    cond do
      file ->
        load_zone_from_file(zone_name, file, zone_type, ttl)

      true ->
        {:error, :no_source_specified}
    end
  end

  defp load_zone_from_file(zone_name, file, zone_type, ttl) do
    # Parse zone file using Zone.Parser
    case Zone.Parser.parse_file(file,
           zone_name: zone_name,
           zone_type: zone_type,
           default_ttl: ttl
         ) do
      {:ok, zone} ->
        # Store zone records in storage
        store_zone_records(zone_name, zone)

        # Store metadata
        metadata = %{
          type: zone_type,
          file: file,
          serial: Zone.get_serial(zone),
          loaded_at: System.system_time(:second)
        }

        Storage.put_zone_metadata(zone_name, metadata)

        Logger.info("Zone loaded from file",
          zone: zone_name,
          file: file,
          type: zone_type,
          record_count: length(zone.records)
        )

        {:ok, zone_name}

      {:error, reason} = error ->
        Logger.error("Failed to parse zone file",
          zone: zone_name,
          file: file,
          error: inspect(reason)
        )

        error
    end
  end

  defp do_load_zone_struct(zone_name, %Zone{} = zone) do
    # Validate zone
    case Zone.validate(zone) do
      :ok ->
        store_zone_records(zone_name, zone)
        {:ok, zone_name}

      {:error, _} = error ->
        error
    end
  end

  defp store_zone_records(zone_name, %Zone{} = zone) do
    # Store SOA if present
    if zone.soa do
      Storage.insert_record(
        zone_name,
        "@",
        :SOA,
        zone.soa,
        zone.ttl
      )
    end

    # Store all records
    Enum.each(zone.records, fn record ->
      Storage.insert_record(
        zone_name,
        record.owner,
        record.type,
        record.rdata,
        record.ttl,
        record.class
      )
    end)

    # Store metadata
    format = Zone.to_storage_format(zone)

    Storage.put_zone_metadata(zone_name, format.metadata)

    Logger.info("Zone records stored",
      zone: zone_name,
      record_count: length(zone.records)
    )

    :ok
  end

  defp count_zone_records(zone_name) do
    case Storage.list_zone_records(zone_name) do
      {:ok, records} -> length(records)
      _ -> 0
    end
  end
end
