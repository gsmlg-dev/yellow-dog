defmodule YellowDog.Dns.ConfigPersistence do
  @moduledoc """
  Orchestration layer for DNS configuration persistence.

  Coordinates ViewStore, ZoneStore, and AclStore to provide a unified interface
  for loading and saving DNS configurations.

  ## File Structure

      data/dns/
      ├── views.toml              # View configurations
      ├── zones.toml              # Zone metadata index
      ├── views/                  # View-specific data
      │   ├── default/
      │   │   └── zones/
      │   │       └── example.com.zone
      │   └── internal/
      │       └── zones/
      │           └── internal.example.com.zone
      ├── acls.toml               # Named ACL configurations
      └── acls/                   # ACL-related data (reserved)

  ## Usage

      # Load all configuration
      {:ok, config} = ConfigPersistence.load_all("data/dns")

      # Save all configuration
      :ok = ConfigPersistence.save_all("data/dns", views, zones, acls)

      # Save individual components
      :ok = ConfigPersistence.save_views("data/dns", views)
      :ok = ConfigPersistence.save_zones("data/dns", zones)
      :ok = ConfigPersistence.save_acls("data/dns", acls)
  """

  alias YellowDog.Dns.ViewStore
  alias YellowDog.Dns.ZoneStore
  alias YellowDog.Dns.AclStore

  @views_file "views.toml"
  @zones_file "zones.toml"
  @views_dir "views"
  @acls_file "acls.toml"
  @acls_dir "acls"

  @type config :: %{
          views: [ViewStore.view_config()],
          zones: [ZoneStore.zone_config()],
          acls: [AclStore.acl_config()]
        }

  @doc """
  Returns the default data path for DNS configuration.
  """
  @spec default_data_path() :: String.t()
  def default_data_path do
    try do
      path = apply(YellowDog.Config, :get, [:dns, :data_path])
      path || "data/dns"
    rescue
      _e in [ArgumentError, UndefinedFunctionError] -> "data/dns"
    catch
      :exit, _reason -> "data/dns"
    end
  end

  @doc """
  Returns the path to the views directory.
  """
  @spec views_path(String.t()) :: String.t()
  def views_path(data_path \\ default_data_path()) do
    Path.join(data_path, @views_dir)
  end

  @doc """
  Returns the path to the zones directory for a specific view.
  """
  @spec zones_path(String.t(), String.t()) :: String.t()
  def zones_path(data_path \\ default_data_path(), view_name) do
    Path.join([data_path, @views_dir, view_name, "zones"])
  end

  @doc """
  Returns the path to the acls directory.
  """
  @spec acls_path(String.t()) :: String.t()
  def acls_path(data_path \\ default_data_path()) do
    Path.join(data_path, @acls_dir)
  end

  @doc """
  Loads all DNS configuration from the specified data directory.

  ## Parameters
  - `data_path` - Path to the DNS data directory (default: from config or "data/dns")

  ## Returns
  - `{:ok, %{views: [...], zones: [...]}}` on success
  - `{:error, reason}` on failure
  """
  @spec load_all(String.t()) :: {:ok, config()} | {:error, term()}
  def load_all(data_path \\ default_data_path()) do
    views_file_path = Path.join(data_path, @views_file)
    zones_file_path = Path.join(data_path, @zones_file)
    acls_file_path = Path.join(data_path, @acls_file)

    with {:ok, views} <- ViewStore.load_views(views_file_path),
         {:ok, zones} <- ZoneStore.load_zones(zones_file_path),
         {:ok, acls} <- AclStore.load_acls(acls_file_path) do
      :telemetry.execute(
        [:yellow_dog, :dns, :config_persistence, :loaded],
        %{view_count: length(views), zone_count: length(zones), acl_count: length(acls)},
        %{data_path: data_path}
      )

      {:ok, %{views: views, zones: zones, acls: acls}}
    else
      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :dns, :config_persistence, :load_failed],
          %{count: 1},
          %{data_path: data_path, reason: inspect(reason)}
        )

        error
    end
  end

  @doc """
  Saves all DNS configuration to the specified data directory.

  ## Parameters
  - `data_path` - Path to the DNS data directory
  - `views` - List of view configurations
  - `zones` - List of zone configurations
  - `acls` - List of ACL configurations (optional, defaults to [])
  - `opts` - Options passed to underlying stores

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_all(
          String.t(),
          [ViewStore.view_config()],
          [ZoneStore.zone_config()],
          [AclStore.acl_config()],
          keyword()
        ) :: :ok | {:error, term()}
  def save_all(data_path \\ default_data_path(), views, zones, acls \\ [], opts \\ []) do
    with :ok <- ensure_data_directory(data_path, views),
         :ok <- save_views(data_path, views, opts),
         :ok <- save_zones(data_path, zones, opts),
         :ok <- save_acls(data_path, acls, opts) do
      :telemetry.execute(
        [:yellow_dog, :dns, :config_persistence, :saved],
        %{view_count: length(views), zone_count: length(zones), acl_count: length(acls)},
        %{data_path: data_path}
      )

      :ok
    end
  end

  @doc """
  Saves view configurations to the data directory.

  ## Parameters
  - `data_path` - Path to the DNS data directory
  - `views` - List of view configurations
  - `opts` - Options passed to ViewStore.save_views/3
  """
  @spec save_views(String.t(), [ViewStore.view_config()], keyword()) :: :ok | {:error, term()}
  def save_views(data_path \\ default_data_path(), views, opts \\ []) do
    views_path = Path.join(data_path, @views_file)

    with :ok <- ensure_data_directory(data_path) do
      ViewStore.save_views(views_path, views, opts)
    end
  end

  @doc """
  Saves zone configurations to the data directory.

  ## Parameters
  - `data_path` - Path to the DNS data directory
  - `zones` - List of zone configurations
  - `opts` - Options passed to ZoneStore.save_zones/3
  """
  @spec save_zones(String.t(), [ZoneStore.zone_config()], keyword()) :: :ok | {:error, term()}
  def save_zones(data_path \\ default_data_path(), zones, opts \\ []) do
    zones_file_path = Path.join(data_path, @zones_file)
    ZoneStore.save_zones(zones_file_path, zones, opts)
  end

  @doc """
  Saves ACL configurations to the data directory.

  ## Parameters
  - `data_path` - Path to the DNS data directory
  - `acls` - List of ACL configurations
  - `opts` - Options (reserved for future use)
  """
  @spec save_acls(String.t(), [AclStore.acl_config()], keyword()) :: :ok | {:error, term()}
  def save_acls(data_path \\ default_data_path(), acls, _opts \\ []) do
    acls_file_path = Path.join(data_path, @acls_file)
    AclStore.save_acls(acls_file_path, acls)
  end

  @doc """
  Collects current view configurations from ViewManager.

  Returns view configs suitable for persistence.
  """
  @spec collect_views() :: [ViewStore.view_config()]
  def collect_views do
    collect_views(YellowDog.Dns.ViewManager)
  end

  @spec collect_views(module() | pid()) :: [ViewStore.view_config()]
  def collect_views(supervisor) do
    alias YellowDog.Dns.{ViewManager, View}

    ViewManager.list_views(supervisor)
    |> Enum.map(fn {name, pid, priority} ->
      try do
        stats = View.stats(pid)

        %{
          name: name,
          priority: priority,
          match_clients: stats[:match_clients],
          recursion: stats[:recursion_enabled] || false,
          ecs_enabled: stats[:ecs_enabled] || false,
          zones: stats[:zones] || [],
          acl: stats[:acl],
          enabled: Map.get(stats, :enabled, true),
          fallback_forwarders: Map.get(stats, :fallback_forwarders, []),
          fallback_timeout: Map.get(stats, :fallback_timeout, 2000),
          fallback_retries: Map.get(stats, :fallback_retries, 1)
        }
      rescue
        _e in [ArgumentError, RuntimeError, MatchError, FunctionClauseError, KeyError] ->
          %{
            name: name,
            priority: priority,
            recursion: false,
            ecs_enabled: false,
            zones: []
          }
      end
    end)
  end

  @doc """
  Collects current zone configurations from ZoneController.

  Returns zone configs suitable for persistence.
  """
  @spec collect_zones() :: [ZoneStore.zone_config()]
  def collect_zones do
    collect_zones(YellowDog.Dns.ZoneController)
  end

  @spec collect_zones(module() | pid()) :: [ZoneStore.zone_config()]
  def collect_zones(supervisor) do
    alias YellowDog.Dns.ZoneController

    ZoneController.list_zones(supervisor)
    |> Enum.map(fn {view_name, type, name, _pid} ->
      %{
        name: name,
        type: type,
        view_name: view_name,
        file: zone_file_path(view_name, name)
      }
    end)
  end

  @doc """
  Generates the zone file path for a zone name.

  Zone files are stored under their respective view directories:
  `views/{view_name}/zones/{zone_name}.zone`

  This allows the same zone name to exist in different views without conflicts.
  """
  @spec zone_file_path(String.t(), String.t()) :: String.t()
  def zone_file_path(view_name, zone_name) do
    Path.join([@views_dir, view_name, "zones", "#{zone_name}.zone"])
  end

  # Backward compatible version for single-arg calls (assumes "default" view)
  @spec zone_file_path(String.t()) :: String.t()
  def zone_file_path(zone_name) do
    zone_file_path("default", zone_name)
  end

  @doc """
  Saves the current DNS configuration from running services.

  Collects views, zones, and ACLs from ViewManager, ZoneController, and AclRegistry,
  then persists them to the data directory.
  """
  @spec save_current(String.t(), keyword()) :: :ok | {:error, term()}
  def save_current(data_path \\ default_data_path(), opts \\ []) do
    views = collect_views()
    zones = collect_zones()
    acls = collect_acls()
    save_all(data_path, views, zones, acls, opts)
  end

  @doc """
  Collects current ACL configurations from AclRegistry.

  Returns ACL configs suitable for persistence.
  """
  @spec collect_acls() :: [AclStore.acl_config()]
  def collect_acls do
    alias YellowDog.Dns.AclRegistry

    try do
      AclRegistry.list_acls()
    rescue
      _e in [ArgumentError, UndefinedFunctionError] -> []
    catch
      :exit, _ -> []
    end
  end

  # Private functions

  defp ensure_data_directory(data_path, views \\ []) do
    views_dir = Path.join(data_path, @views_dir)
    acls_dir = Path.join(data_path, @acls_dir)

    with :ok <- File.mkdir_p(data_path),
         :ok <- File.mkdir_p(views_dir),
         :ok <- File.mkdir_p(acls_dir),
         :ok <- ensure_view_directories(data_path, views) do
      :ok
    end
  end

  defp ensure_view_directories(data_path, views) do
    # Create zones directory for each view
    Enum.reduce_while(views, :ok, fn view, :ok ->
      view_name = view[:name] || view.name
      view_zones_dir = Path.join([data_path, @views_dir, view_name, "zones"])

      case File.mkdir_p(view_zones_dir) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
