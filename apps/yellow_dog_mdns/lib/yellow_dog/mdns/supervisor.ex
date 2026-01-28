defmodule YellowDog.Mdns.Supervisor do
  @moduledoc """
  The main supervisor for the YellowDog mDNS service.

  Manages the mDNS server and related components with proper supervision
  and lifecycle management.
  """

  use Supervisor

  @doc """
  Starts the mDNS server supervisor.

  ## Options
  - `:name` - Name for the supervisor (default: YellowDog.Mdns)
  - `:server_options` - Options to pass to the mDNS server

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, YellowDog.Mdns)
    opts = Map.put(opts, :name, name)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    children = build_children(opts)
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children(opts) do
    server_options = Map.get(opts, :server_options, [])

    # Extract configuration from server_options
    storage_file = Keyword.get(server_options, :storage_file, "data/mdns/services.toml")
    storage_format = Keyword.get(server_options, :storage_format, :toml)
    auto_save = Keyword.get(server_options, :auto_save, true)
    watch_file = Keyword.get(server_options, :watch_file, true)
    load_on_start = Keyword.get(server_options, :load_on_start, true)

    # Build service registry options
    registry_opts = [
      storage_file: storage_file,
      auto_save: auto_save,
      load_on_start: load_on_start
    ]

    # Build file watcher options
    watcher_opts = [
      file_path: storage_file,
      format: storage_format,
      enabled: watch_file
    ]

    [
      # Pre-start task
      {Task,
       fn ->
         :telemetry.execute(
           [:yellow_dog, :mdns, :supervisor, :pre_start],
           %{count: 1},
           %{}
         )
       end}
      |> Supervisor.child_spec(id: :pre_start, restart: :temporary),

      # Rate limiter - must start before server for DoS protection
      YellowDog.Mdns.RateLimiter
      |> Supervisor.child_spec(id: :rate_limiter),

      # Service Registry - must start first (others depend on it)
      {YellowDog.Mdns.ServiceRegistry, registry_opts}
      |> Supervisor.child_spec(id: :service_registry),

      # File Watcher - watches service file for changes
      {YellowDog.Mdns.FileWatcher, watcher_opts}
      |> Supervisor.child_spec(id: :file_watcher),

      # Network Monitor - enhanced caching with query tracking
      {YellowDog.Mdns.NetworkMonitor, []}
      |> Supervisor.child_spec(id: :network_monitor),

      # Message Cache - legacy compatibility, must start before server
      {YellowDog.Mdns.MessageCache, []}
      |> Supervisor.child_spec(id: :message_cache),

      # mDNS Server - UDP multicast server
      {YellowDog.Mdns.Server, server_options}
      |> Supervisor.child_spec(id: :server),

      # Post-start task
      {Task,
       fn ->
         mode = Keyword.get(server_options, :mode, :hybrid)

         :telemetry.execute(
           [:yellow_dog, :mdns, :supervisor, :post_start],
           %{count: 1},
           %{mode: mode}
         )
       end}
      |> Supervisor.child_spec(id: :post_start, restart: :temporary)
    ]
  end
end
