defmodule YellowDog.Mdns.FileWatcher do
  @moduledoc """
  Watches the services configuration file for changes and triggers hot-reload.

  Uses FileSystem library to monitor file changes and notifies the ServiceRegistry
  when the file is modified, enabling live configuration updates without restart.
  """

  use GenServer
  require Logger

  alias YellowDog.Mdns.{ServiceStore, ServiceRegistry}

  @type options :: [
          file_path: String.t(),
          format: :toml | :json,
          enabled: boolean()
        ]

  # Client API

  @doc """
  Starts the FileWatcher GenServer.

  ## Options
  - `:file_path` - Path to the services file to watch (required)
  - `:format` - File format (:toml or :json), defaults to auto-detect
  - `:enabled` - Enable file watching (default: true)

  ## Examples
      iex> YellowDog.Mdns.FileWatcher.start_link(file_path: "/path/to/services.toml")
      {:ok, #PID<0.123.0>}
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers a reload of the services file.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.cast(__MODULE__, :reload)
  end

  @doc """
  Gets the current watcher status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    file_path = Keyword.fetch!(opts, :file_path)
    format = Keyword.get(opts, :format)
    enabled = Keyword.get(opts, :enabled, true)

    state = %{
      file_path: file_path,
      format: format,
      enabled: enabled,
      watcher_pid: nil,
      last_loaded: nil,
      reload_count: 0
    }

    if enabled do
      case start_file_watcher(file_path) do
        {:ok, watcher_pid} ->
          Logger.info("FileWatcher started for #{file_path}")
          {:ok, %{state | watcher_pid: watcher_pid}}

        {:error, reason} ->
          Logger.error("Failed to start file watcher: #{inspect(reason)}")
          {:ok, state}
      end
    else
      Logger.info("FileWatcher disabled")
      {:ok, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    # Only reload if the file was modified or renamed
    should_reload =
      Enum.any?(events, fn event ->
        event in [:modified, :renamed, :created]
      end)

    if should_reload and Path.basename(path) == Path.basename(state.file_path) do
      Logger.info("Services file changed, reloading: #{path}")
      handle_reload(state)
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("File watcher stopped")
    {:noreply, %{state | watcher_pid: nil}}
  end

  @impl true
  def handle_cast(:reload, state) do
    handle_reload(state)
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.enabled,
      watching: not is_nil(state.watcher_pid),
      file_path: state.file_path,
      last_loaded: state.last_loaded,
      reload_count: state.reload_count
    }

    {:reply, status, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.watcher_pid do
      FileSystem.stop(state.watcher_pid)
    end

    :ok
  end

  # Private functions

  defp start_file_watcher(file_path) do
    # Watch the directory containing the file
    dir = Path.dirname(file_path)

    case FileSystem.start_link(dirs: [dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        {:ok, pid}

      error ->
        error
    end
  end

  defp handle_reload(state) do
    # Add a small delay to ensure file write is complete
    Process.sleep(100)

    case ServiceStore.load_services(state.file_path, format: state.format) do
      {:ok, services} ->
        # Notify ServiceRegistry to reload services
        ServiceRegistry.reload_from_file(services)

        :telemetry.execute(
          [:yellow_dog, :mdns, :file_reloaded],
          %{service_count: length(services)},
          %{file_path: state.file_path}
        )

        {:noreply,
         %{
           state
           | last_loaded: System.system_time(:second),
             reload_count: state.reload_count + 1
         }}

      {:error, reason} ->
        Logger.error("Failed to reload services from file: #{inspect(reason)}")

        :telemetry.execute(
          [:yellow_dog, :mdns, :file_reload_error],
          %{},
          %{reason: inspect(reason), file_path: state.file_path}
        )

        {:noreply, state}
    end
  end
end
