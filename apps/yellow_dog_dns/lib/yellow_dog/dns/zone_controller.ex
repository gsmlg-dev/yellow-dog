defmodule YellowDog.Dns.ZoneController do
  @moduledoc """
  Supervisor for DNS zone processes.

  The ZoneController manages the lifecycle of zone processes:
  - Auth zones (authoritative data)
  - Forward zones (upstream forwarding)
  - Stub zones (NS delegation)
  - Root zone (root hints)
  - Cache zones (query caching)

  Zones are scoped to views - each view can have its own set of zones
  with the same names without conflict.

  Zones can be dynamically added, removed, and reloaded.
  """

  use DynamicSupervisor

  alias YellowDog.Telemetry

  # Default view name for zones not explicitly assigned to a view
  @default_view "default"

  @doc """
  Starts the ZoneController supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Telemetry.info("ZoneController starting")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a zone process.

  ## Parameters

  - `zone_type` - Type of zone (:auth, :forward, :stub, :root, :cache)
  - `zone_name` - Name of the zone (e.g., "example.com")
  - `config` - Zone-specific configuration
    - `:view_name` - View this zone belongs to (default: "default")
    - Other zone-specific options

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start_zone(atom(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_zone(zone_type, zone_name, config \\ []) do
    start_zone(__MODULE__, zone_type, zone_name, config)
  end

  @spec start_zone(Supervisor.supervisor(), atom(), String.t(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_zone(supervisor, zone_type, zone_name, config) do
    view_name = Keyword.get(config, :view_name, @default_view)

    # Persist zone metadata to Store if not already present
    ensure_zone_in_store(view_name, zone_type, zone_name, config)

    module = zone_module(zone_type)
    opts = Keyword.merge(config, name: zone_name, view_name: view_name)

    # Add zone_data_path for auth zones to enable persistence
    opts =
      if zone_type == :auth do
        case get_zone_data_path() do
          nil -> opts
          path -> Keyword.put_new(opts, :zone_data_path, path)
        end
      else
        opts
      end

    # Zone ID is scoped to view: {view_name, zone_type, zone_name}
    child_spec = %{
      id: {view_name, zone_type, zone_name},
      start: {module, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} = result ->
        Telemetry.info("Zone started", %{
          view: view_name,
          type: zone_type,
          name: zone_name,
          pid: inspect(pid)
        })

        result

      {:error, reason} = error ->
        Telemetry.error("Failed to start zone", %{
          view: view_name,
          type: zone_type,
          name: zone_name,
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Loads all zones from Store and starts their processes.

  Called during DNS supervisor startup to restore persisted zones.
  Returns the count of zones successfully started.
  """
  @spec load_zones_from_store() :: {:ok, non_neg_integer()}
  def load_zones_from_store do
    load_zones_from_store(__MODULE__)
  end

  @spec load_zones_from_store(Supervisor.supervisor()) :: {:ok, non_neg_integer()}
  def load_zones_from_store(supervisor) do
    try do
      case YellowDog.Store.Zone.list_zones() do
        {:ok, zones} when is_list(zones) ->
          started =
            Enum.count(zones, fn zone ->
              zone_type = Map.get(zone, :zone_type)
              origin = Map.get(zone, :origin)
              view_name = extract_view_from_zone(zone)

              if zone_type && origin do
                case start_zone(supervisor, zone_type, origin, view_name: view_name) do
                  {:ok, _pid} -> true
                  {:error, {:already_started, _}} -> true
                  _ -> false
                end
              else
                false
              end
            end)

          Telemetry.info("Loaded zones from Store", %{count: started})
          {:ok, started}

        _ ->
          {:ok, 0}
      end
    rescue
      error ->
        Telemetry.warning("Failed to load zones from Store", %{error: inspect(error)})
        {:ok, 0}
    end
  end

  @doc """
  Stops a zone process.

  ## Parameters

  - `view_name` - View the zone belongs to
  - `zone_type` - Type of zone
  - `zone_name` - Name of the zone
  """
  @spec stop_zone(String.t(), atom(), String.t()) :: :ok | {:error, :not_found}
  def stop_zone(view_name, zone_type, zone_name) do
    stop_zone(__MODULE__, view_name, zone_type, zone_name)
  end

  # Backward compatible version without view_name (uses default view)
  @spec stop_zone(atom(), String.t()) :: :ok | {:error, :not_found}
  def stop_zone(zone_type, zone_name) when is_atom(zone_type) do
    stop_zone(__MODULE__, @default_view, zone_type, zone_name)
  end

  @spec stop_zone(Supervisor.supervisor(), String.t(), atom(), String.t()) ::
          :ok | {:error, :not_found}
  def stop_zone(supervisor, view_name, zone_type, zone_name) do
    case find_zone(supervisor, view_name, zone_type, zone_name) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(supervisor, pid)

        Telemetry.info("Zone stopped", %{view: view_name, type: zone_type, name: zone_name})
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Finds a zone process by view, type and name.
  """
  @spec find_zone(String.t(), atom(), String.t()) :: {:ok, pid()} | :error
  def find_zone(view_name, zone_type, zone_name) do
    find_zone(__MODULE__, view_name, zone_type, zone_name)
  end

  # Backward compatible version without view_name (uses default view)
  @spec find_zone(atom(), String.t()) :: {:ok, pid()} | :error
  def find_zone(zone_type, zone_name) when is_atom(zone_type) do
    find_zone(__MODULE__, @default_view, zone_type, zone_name)
  end

  @spec find_zone(Supervisor.supervisor(), String.t(), atom(), String.t()) ::
          {:ok, pid()} | :error
  def find_zone(supervisor, view_name, zone_type, zone_name) do
    module = zone_module(zone_type)
    children = DynamicSupervisor.which_children(supervisor)

    # First try exact ID match
    case Enum.find(children, fn {id, _pid, _type, _modules} ->
           id == {view_name, zone_type, zone_name}
         end) do
      {_id, pid, _type, _modules} when is_pid(pid) -> {:ok, pid}
      _ -> find_by_module_view_and_name(children, module, view_name, zone_name)
    end
  end

  @doc """
  Lists all active zones.

  Returns a list of tuples: `{view_name, zone_type, zone_name, pid}`
  """
  @spec list_zones() :: [{String.t(), atom(), String.t(), pid()}]
  def list_zones do
    list_zones(__MODULE__)
  end

  @spec list_zones(Supervisor.supervisor()) :: [{String.t(), atom(), String.t(), pid()}]
  def list_zones(supervisor) do
    for {id, pid, _type, modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid),
        {view_name, zone_type, zone_name} = extract_zone_info(id, pid, modules),
        zone_name != nil do
      {view_name, zone_type, zone_name, pid}
    end
  end

  @doc """
  Lists zones for a specific view.
  """
  @spec list_zones_for_view(String.t()) :: [{atom(), String.t(), pid()}]
  def list_zones_for_view(view_name) do
    list_zones_for_view(__MODULE__, view_name)
  end

  @spec list_zones_for_view(Supervisor.supervisor(), String.t()) :: [{atom(), String.t(), pid()}]
  def list_zones_for_view(supervisor, view_name) do
    for {^view_name, type, name, pid} <- list_zones(supervisor), do: {type, name, pid}
  end

  defp extract_zone_info({view_name, zone_type, zone_name}, _pid, _modules),
    do: {view_name, zone_type, zone_name}

  defp extract_zone_info({zone_type, zone_name}, _pid, _modules),
    do: {@default_view, zone_type, zone_name}

  defp extract_zone_info(_id, pid, modules) do
    zone_type = module_to_zone_type(List.first(modules))
    {get_zone_view_from_pid(modules, pid), zone_type, get_zone_name_from_pid(modules, pid)}
  end

  # Map module back to zone type
  defp module_to_zone_type(YellowDog.Dns.Zone.Auth), do: :auth
  defp module_to_zone_type(YellowDog.Dns.Zone.Forward), do: :forward
  defp module_to_zone_type(YellowDog.Dns.Zone.Stub), do: :stub
  defp module_to_zone_type(YellowDog.Dns.Zone.Root), do: :root
  defp module_to_zone_type(YellowDog.Dns.Zone.Cache), do: :cache
  defp module_to_zone_type(YellowDog.Dns.Zone.RPZ), do: :rpz
  defp module_to_zone_type(_), do: :unknown

  # Get zone name from process
  defp get_zone_name_from_pid(modules, pid) do
    safe_call_module(modules, pid, :get_name, nil)
  end

  # Get zone view from process
  defp get_zone_view_from_pid(modules, pid) do
    safe_call_module(modules, pid, :get_view, @default_view)
  end

  # Safely call a module function with default fallback on error
  defp safe_call_module(modules, pid, function, default) do
    module = List.first(modules)

    try do
      apply(module, function, [pid])
    catch
      _, _ -> default
    end
  end

  @doc """
  Reloads a zone with new configuration.
  """
  @spec reload_zone(String.t(), atom(), String.t(), keyword()) :: :ok | {:error, term()}
  def reload_zone(view_name, zone_type, zone_name, config) do
    reload_zone(__MODULE__, view_name, zone_type, zone_name, config)
  end

  # Backward compatible version without view_name
  @spec reload_zone(atom(), String.t(), keyword()) :: :ok | {:error, term()}
  def reload_zone(zone_type, zone_name, config) when is_atom(zone_type) do
    reload_zone(__MODULE__, @default_view, zone_type, zone_name, config)
  end

  @spec reload_zone(Supervisor.supervisor(), String.t(), atom(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def reload_zone(supervisor, view_name, zone_type, zone_name, config) do
    case find_zone(supervisor, view_name, zone_type, zone_name) do
      {:ok, pid} ->
        module = zone_module(zone_type)
        module.reload(pid, config)

      :error ->
        {:error, :not_found}
    end
  end

  # Maps zone type atoms to module names
  defp zone_module(:auth), do: YellowDog.Dns.Zone.Auth
  defp zone_module(:forward), do: YellowDog.Dns.Zone.Forward
  defp zone_module(:stub), do: YellowDog.Dns.Zone.Stub
  defp zone_module(:root), do: YellowDog.Dns.Zone.Root
  defp zone_module(:cache), do: YellowDog.Dns.Zone.Cache
  defp zone_module(:rpz), do: YellowDog.Dns.Zone.RPZ

  defp find_by_module_view_and_name(children, module, view_name, zone_name) do
    Enum.find_value(children, :error, fn {_id, pid, _type, modules} ->
      if is_pid(pid) and module in modules do
        # Check if this is the right zone by calling get_name and get_view
        try do
          pid_name = module.get_name(pid)

          pid_view =
            try do
              module.get_view(pid)
            catch
              _, _ -> @default_view
            end

          if pid_name == zone_name and pid_view == view_name do
            {:ok, pid}
          else
            nil
          end
        catch
          _, _ -> nil
        end
      else
        nil
      end
    end)
  end

  # Get zone data path from config with fallback to default
  defp get_zone_data_path do
    try do
      apply(YellowDog.Config, :get, [:dns, :zone_data_path]) ||
        default_zone_data_path()
    rescue
      _e in [ArgumentError, UndefinedFunctionError] -> default_zone_data_path()
    end
  end

  defp default_zone_data_path do
    # Default to priv/zones directory
    case :code.priv_dir(:yellow_dog_dns) do
      {:error, _} -> "priv/zones"
      path -> Path.join(to_string(path), "zones")
    end
  end

  # Persist zone metadata to Store before starting the process (CAS: no-op if exists)
  defp ensure_zone_in_store(view_name, zone_type, zone_name, config) do
    try do
      case zone_type do
        :auth ->
          soa = Keyword.get(config, :soa, YellowDog.Store.Zone.default_soa(zone_name))
          opts = Keyword.take(config, [:default_ttl, :serial_strategy, :cloud_mirror])
          YellowDog.Store.Zone.create_zone(view_name, zone_name, soa, opts)

        :forward ->
          forwarders = store_forwarders_from_config(config)
          opts = Keyword.take(config, [:forward_mode, :timeout_ms, :max_retries])
          YellowDog.Store.Zone.create_forward_zone(view_name, zone_name, forwarders, opts)

        :stub ->
          primaries = store_primaries_from_config(config)
          opts = Keyword.take(config, [:refresh_interval])
          YellowDog.Store.Zone.create_stub_zone(view_name, zone_name, primaries, opts)

        _ ->
          :ok
      end
    rescue
      error ->
        Telemetry.warning("Failed to persist zone to Store", %{
          view: view_name,
          type: zone_type,
          name: zone_name,
          error: inspect(error)
        })

        :ok
    end
  end

  defp store_forwarders_from_config(config) do
    upstreams = Keyword.get(config, :upstreams, [])

    Enum.flat_map(upstreams, fn
      {ip, port} when is_tuple(ip) ->
        [%{ip: :inet.ntoa(ip) |> to_string(), port: port}]

      ip_str when is_binary(ip_str) ->
        [%{ip: ip_str, port: 53}]

      _ ->
        []
    end)
  end

  defp store_primaries_from_config(config) do
    glue_records = Keyword.get(config, :glue_records, %{})

    Enum.flat_map(glue_records, fn {_hostname, ip} ->
      case ip do
        ip when is_tuple(ip) ->
          [%{ip: :inet.ntoa(ip) |> to_string(), port: 53}]

        _ ->
          []
      end
    end)
  end

  # Extract view_name from zone metadata returned by Store
  defp extract_view_from_zone(zone) do
    # Zone metadata from Store doesn't include view_name directly;
    # the view is encoded in the Store key. For list_zones(), we extract
    # from the key pattern or default to "default".
    Map.get(zone, :view_name, @default_view)
  end
end
