defmodule YellowDog.Mdns do
  @moduledoc """
  mDNS service discovery and responder.

  Provides a complete mDNS implementation with:
  - Service registration and advertising
  - Network discovery and monitoring
  - Query response (RFC 6762 compliant)
  - File-based persistence
  - Hot-reload configuration
  """

  alias YellowDog.Mdns.{MessageCache, NetworkMonitor, ServiceRegistry, Supervisor}

  # Supervisor API

  @doc """
  Starts the Mdns supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options), to: Supervisor

  @doc """
  Returns a child specification for the Mdns supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: Supervisor

  # Service Registration API

  @doc """
  Registers a new mDNS service.

  ## Parameters
  - `service_def` - Service definition map with:
    - `:name` (required) - Service name
    - `:type` (required) - Service type (e.g., "_http._tcp")
    - `:port` (required) - Port number
    - `:txt` (optional) - TXT record key-value map
    - `:addresses` (optional) - List of IP addresses
    - `:enabled` (optional) - Enable/disable (default: true)
  - `opts` - Options:
    - `:persist` - Save to file (default: false)

  ## Examples
      iex> YellowDog.Mdns.register_service(%{
      ...>   name: "My Web Server",
      ...>   type: "_http._tcp",
      ...>   port: 8080,
      ...>   txt: %{"version" => "1.0"},
      ...>   addresses: ["192.168.1.100"]
      ...> }, persist: true)
      {:ok, "My Web Server._http._tcp.local"}
  """
  @spec register_service(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate register_service(service_def, opts \\ []), to: ServiceRegistry

  @doc """
  Unregisters a service.
  """
  @spec unregister_service(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate unregister_service(service_id, opts \\ []), to: ServiceRegistry

  @doc """
  Lists all registered services.

  ## Options
  - `:filter` - Filter by state (:all, :enabled, :disabled, :registered)
  - `:source` - Filter by source (:file, :api, :all)
  """
  @spec list_registered_services(keyword()) :: [map()]
  def list_registered_services(opts \\ []) do
    ServiceRegistry.list_services(opts)
  end

  @doc """
  Gets a registered service by ID.
  """
  @spec get_registered_service(String.t()) :: map() | nil
  defdelegate get_registered_service(service_id), to: ServiceRegistry, as: :get_service

  @doc """
  Updates a registered service.
  """
  @spec update_service(String.t(), map(), keyword()) :: :ok | {:error, term()}
  defdelegate update_service(service_id, updates, opts \\ []), to: ServiceRegistry

  @doc """
  Toggles a service enabled/disabled state.
  """
  @spec toggle_service(String.t()) :: :ok | {:error, term()}
  defdelegate toggle_service(service_id), to: ServiceRegistry

  # Network Discovery API

  @doc """
  Lists all discovered services on the network.

  ## Returns
  - List of discovered service maps with name, type, host, port, etc.
  """
  @spec list_discovered_services() :: [map()]
  defdelegate list_discovered_services(), to: NetworkMonitor

  @doc """
  Gets details about a specific discovered service.
  """
  @spec get_discovered_service(String.t()) :: map() | nil
  defdelegate get_discovered_service(service_id), to: NetworkMonitor

  @doc """
  Searches for services by type.

  ## Examples
      iex> YellowDog.Mdns.discover_services(type: "_http._tcp")
      [%{name: "Web Server", type: "_http._tcp.local", ...}]
  """
  @spec discover_services(keyword()) :: [map()]
  def discover_services(opts \\ []) do
    NetworkMonitor.search_services(opts)
  end

  @doc """
  Gets network activity statistics.

  ## Returns
  - Map with:
    - `total_responses` - Total cached responses
    - `total_queries` - Total logged queries
    - `active_services` - Number of discovered services
    - `unique_hosts` - Number of unique hosts seen
    - `queries_per_minute` - Query rate
    - `most_queried_services` - Top queried services

  ## Examples
      iex> YellowDog.Mdns.network_stats()
      %{
        unique_hosts: 15,
        active_services: 42,
        queries_per_minute: 8.5,
        ...
      }
  """
  @spec network_stats() :: map()
  defdelegate network_stats(), to: NetworkMonitor

  @doc """
  Gets recent mDNS queries seen on the network.

  ## Options
  - `:limit` - Maximum number of queries (default: 100)
  - `:since` - Unix timestamp to filter from
  """
  @spec get_recent_queries(keyword()) :: [map()]
  def get_recent_queries(opts \\ []) do
    NetworkMonitor.get_queries(opts)
  end

  # Legacy Cache API (backward compatibility)

  @doc """
  Queries cached mDNS messages by domain.

  ## Parameters
  - `domain` - Domain name to search for
  - `record_type` - Optional record type filter

  ## Examples
      iex> YellowDog.Mdns.query("printer.local")
      [%{domain: "printer.local", record_type: :A, ...}]
  """
  @spec query(String.t(), atom() | nil) :: [map()]
  def query(domain, record_type \\ nil) do
    NetworkMonitor.query(domain, record_type)
  end

  @doc """
  Lists all cached mDNS messages.
  """
  @spec list_all() :: [map()]
  defdelegate list_all(), to: NetworkMonitor

  @doc """
  Gets cache statistics.
  """
  @spec stats() :: map()
  def stats do
    NetworkMonitor.stats()
  end

  @doc """
  Clears all entries from the cache.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    MessageCache.clear()
    NetworkMonitor.clear()
  end

  # Status API

  @doc """
  Gets comprehensive status of the mDNS service.

  ## Returns
  - Map with:
    - `running` - Boolean indicating if service is running
    - `mode` - Operating mode (:listener, :responder, :hybrid)
    - `registered_services` - Count of registered services
    - `discovered_services` - Count of discovered services
    - `network_stats` - Network activity statistics
    - `registry_stats` - Service registry statistics

  ## Examples
      iex> YellowDog.Mdns.status()
      %{
        running: true,
        mode: :hybrid,
        registered_services: 3,
        discovered_services: 42,
        ...
      }
  """
  @spec status() :: map()
  def status do
    # Supervisor registers with name YellowDog.Mdns, not YellowDog.Mdns.Supervisor
    case Process.whereis(YellowDog.Mdns) do
      nil ->
        %{
          running: false,
          mode: :unknown,
          registered_services: 0,
          discovered_services: 0,
          network_stats: %{},
          registry_stats: %{}
        }

      _pid ->
        registry_stats = ServiceRegistry.stats()
        net_stats = NetworkMonitor.network_stats()
        mode = get_mode_from_config()

        %{
          running: true,
          mode: mode,
          registered_services: registry_stats.total,
          discovered_services: net_stats.active_services,
          network_stats: net_stats,
          registry_stats: registry_stats
        }
    end
  end

  # Shared Utilities

  @doc """
  Normalizes an mDNS name: converts to lowercase string, strips trailing dot.
  """
  @spec normalize_name(String.t() | atom()) :: String.t()
  def normalize_name(name) do
    name |> to_string() |> String.downcase() |> String.trim_trailing(".")
  end

  defp get_mode_from_config do
    Application.get_env(:yellow_dog_mdns, :mode, :hybrid)
  end
end
