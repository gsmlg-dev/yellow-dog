defmodule YellowDog.Dns.ConfigPersistence do
  @moduledoc """
  Orchestration layer for DNS configuration persistence.

  Coordinates ViewStore and ZoneStore to provide a unified interface
  for loading and saving DNS configurations.

  ## File Structure

      data/dns/
      ├── views.toml              # View configurations
      ├── zones.toml              # Zone metadata
      └── zones/
          ├── example.com.zone    # BIND zone files
          └── internal.example.com.zone

  ## Usage

      # Load all configuration
      {:ok, config} = ConfigPersistence.load_all("data/dns")

      # Save all configuration
      :ok = ConfigPersistence.save_all("data/dns", views, zones)

      # Save individual components
      :ok = ConfigPersistence.save_views("data/dns", views)
      :ok = ConfigPersistence.save_zones("data/dns", zones)
  """

  alias YellowDog.Dns.ViewStore
  alias YellowDog.Dns.ZoneStore

  @views_file "views.toml"
  @zones_file "zones.toml"
  @zones_dir "zones"

  @type config :: %{
          views: [ViewStore.view_config()],
          zones: [ZoneStore.zone_config()]
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
      _ -> "data/dns"
    end
  end

  @doc """
  Returns the path to the zones directory.
  """
  @spec zones_path(String.t()) :: String.t()
  def zones_path(data_path \\ default_data_path()) do
    Path.join(data_path, @zones_dir)
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
    views_path = Path.join(data_path, @views_file)
    zones_path = Path.join(data_path, @zones_file)

    with {:ok, views} <- ViewStore.load_views(views_path),
         {:ok, zones} <- ZoneStore.load_zones(zones_path) do
      :telemetry.execute(
        [:yellow_dog, :dns, :config_persistence, :loaded],
        %{view_count: length(views), zone_count: length(zones)},
        %{data_path: data_path}
      )

      {:ok, %{views: views, zones: zones}}
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
  - `opts` - Options passed to underlying stores

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_all(String.t(), [ViewStore.view_config()], [ZoneStore.zone_config()], keyword()) ::
          :ok | {:error, term()}
  def save_all(data_path \\ default_data_path(), views, zones, opts \\ []) do
    with :ok <- ensure_data_directory(data_path),
         :ok <- save_views(data_path, views, opts),
         :ok <- save_zones(data_path, zones, opts) do
      :telemetry.execute(
        [:yellow_dog, :dns, :config_persistence, :saved],
        %{view_count: length(views), zone_count: length(zones)},
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
    zones_path = Path.join(data_path, @zones_file)

    with :ok <- ensure_data_directory(data_path) do
      ZoneStore.save_zones(zones_path, zones, opts)
    end
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
          acl: stats[:acl]
        }
      rescue
        _ ->
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

  Zone files are scoped by view to allow same zone names in different views.
  The default view uses the zone name directly, other views use a prefixed path.
  """
  @spec zone_file_path(String.t(), String.t()) :: String.t()
  def zone_file_path(view_name, zone_name) do
    # Default view zones go in zones/ directly, other views get their own subdirectory
    if view_name == "default" do
      Path.join(@zones_dir, "#{zone_name}.zone")
    else
      Path.join([@zones_dir, view_name, "#{zone_name}.zone"])
    end
  end

  # Backward compatible version for single-arg calls
  @spec zone_file_path(String.t()) :: String.t()
  def zone_file_path(zone_name) do
    zone_file_path("default", zone_name)
  end

  @doc """
  Saves the current DNS configuration from running services.

  Collects views and zones from ViewManager and ZoneController,
  then persists them to the data directory.
  """
  @spec save_current(String.t(), keyword()) :: :ok | {:error, term()}
  def save_current(data_path \\ default_data_path(), opts \\ []) do
    views = collect_views()
    zones = collect_zones()
    save_all(data_path, views, zones, opts)
  end

  # Private functions

  defp ensure_data_directory(data_path) do
    zones_dir = Path.join(data_path, @zones_dir)

    with :ok <- File.mkdir_p(data_path),
         :ok <- File.mkdir_p(zones_dir) do
      :ok
    end
  end
end
