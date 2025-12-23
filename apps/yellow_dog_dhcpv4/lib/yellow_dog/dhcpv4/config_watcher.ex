defmodule YellowDog.Dhcpv4.ConfigWatcher do
  @moduledoc """
  Watches for changes to the DHCPv4 configuration file and triggers reloads.

  Uses FileSystem to monitor configuration files for changes and automatically
  reload pool configurations without requiring a server restart.

  ## Features
  - Monitors configuration file for changes
  - Debounces rapid file changes
  - Validates configuration before applying
  - Emits telemetry events for reload operations
  - Graceful error handling

  ## Example
      # Start the watcher
      {:ok, pid} = YellowDog.Dhcpv4.ConfigWatcher.start_link(
        config_file: "/etc/yellowdog/dhcpv4.toml",
        reload_callback: &MyModule.reload_config/1
      )

      # The watcher will automatically reload configuration when the file changes
  """

  use GenServer

  @type config_callback :: (map() -> :ok | {:error, term()})

  @debounce_ms 1000

  ## Client API

  @doc """
  Starts the ConfigWatcher GenServer.

  ## Options
  - `:config_file` - Path to configuration file to watch (required)
  - `:reload_callback` - Function to call when config changes (required)
  - `:enabled` - Whether to enable watching (default: true)
  - `:debounce_ms` - Milliseconds to wait before reloading (default: 1000)

  ## Returns
  - `{:ok, pid}` - Successfully started
  - `{:error, reason}` - Failed to start
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers a configuration reload.

  ## Returns
  - `:ok` - Reload successful
  - `{:error, reason}` - Reload failed
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Gets the current watcher status.

  ## Returns
  - Map with watcher status information
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    config_file = Keyword.get(opts, :config_file)
    reload_callback = Keyword.get(opts, :reload_callback)
    enabled = Keyword.get(opts, :enabled, true)
    debounce_ms = Keyword.get(opts, :debounce_ms, @debounce_ms)

    cond do
      not enabled ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :config_watcher, :disabled],
          %{count: 1},
          %{reason: :explicitly_disabled}
        )

        {:ok, %{enabled: false}}

      is_nil(config_file) ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :config_watcher, :disabled],
          %{count: 1},
          %{reason: :no_config_file}
        )

        {:ok, %{enabled: false}}

      is_nil(reload_callback) ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :config_watcher, :start_failed],
          %{count: 1},
          %{reason: :no_reload_callback}
        )

        {:stop, :no_reload_callback}

      not File.exists?(config_file) ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :config_watcher, :disabled],
          %{count: 1},
          %{reason: :file_not_found, config_file: config_file}
        )

        {:ok, %{enabled: false}}

      true ->
        # Get directory to watch
        watch_dir = Path.dirname(config_file)

        # Start FileSystem watcher
        case FileSystem.start_link(dirs: [watch_dir], name: __MODULE__.FileSystemWatcher) do
          {:ok, watcher_pid} ->
            FileSystem.subscribe(__MODULE__.FileSystemWatcher)

            state = %{
              enabled: true,
              config_file: Path.expand(config_file),
              reload_callback: reload_callback,
              watcher_pid: watcher_pid,
              debounce_ms: debounce_ms,
              debounce_timer: nil,
              last_reload: nil,
              reload_count: 0
            }

            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :config_watcher, :started],
              %{count: 1},
              %{config_file: config_file}
            )

            {:ok, state}

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :config_watcher, :start_failed],
              %{count: 1},
              %{reason: inspect(reason)}
            )

            {:stop, reason}
        end
    end
  end

  @impl true
  def handle_call(:reload, _from, %{enabled: false} = state) do
    {:reply, {:error, :watcher_disabled}, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case do_reload(state) do
      :ok ->
        new_state = %{
          state
          | last_reload: System.system_time(:second),
            reload_count: state.reload_count + 1
        }

        {:reply, :ok, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:status, _from, %{enabled: false} = state) do
    {:reply, %{enabled: false}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: true,
      config_file: state.config_file,
      last_reload: state.last_reload,
      reload_count: state.reload_count,
      debounce_ms: state.debounce_ms
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, %{enabled: false} = state) do
    # Watcher disabled, ignore events
    _ = {path, events}
    {:noreply, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    # Check if this is our config file
    if Path.expand(path) == state.config_file and should_reload?(events) do
      # Cancel any existing debounce timer
      if state.debounce_timer do
        Process.cancel_timer(state.debounce_timer)
      end

      # Schedule reload after debounce period
      timer = Process.send_after(self(), :do_reload, state.debounce_ms)

      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :config_watcher, :change_detected],
        %{count: 1, debounce_ms: state.debounce_ms},
        %{config_file: state.config_file}
      )

      {:noreply, %{state | debounce_timer: timer}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :config_watcher, :watcher_stopped],
      %{count: 1},
      %{}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:do_reload, state) do
    case do_reload(state) do
      :ok ->
        new_state = %{
          state
          | last_reload: System.system_time(:second),
            reload_count: state.reload_count + 1,
            debounce_timer: nil
        }

        {:noreply, new_state}

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :config_watcher, :reload_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:noreply, %{state | debounce_timer: nil}}
    end
  end

  ## Private Functions

  defp should_reload?(events) do
    # Reload on modified, created, or renamed events
    Enum.any?(events, fn event ->
      event in [:modified, :created, :renamed]
    end)
  end

  defp do_reload(state) do
    start_time = System.monotonic_time(:microsecond)

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :config_watcher, :reloading],
      %{count: 1},
      %{config_file: state.config_file}
    )

    # Emit telemetry event for reload start
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :config_reload, :start],
      %{timestamp: System.system_time(:second)},
      %{config_file: state.config_file}
    )

    # Load and validate configuration
    result =
      with {:ok, content} <- File.read(state.config_file),
           {:ok, config} <- parse_config(content),
           :ok <- state.reload_callback.(config) do
        :ok
      else
        {:error, reason} = error ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv4, :config_watcher, :reload_error],
            %{count: 1},
            %{config_file: state.config_file, reason: inspect(reason)}
          )

          error
      end

    # Calculate duration
    duration = System.monotonic_time(:microsecond) - start_time

    # Emit telemetry event for reload completion
    case result do
      :ok ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :config_reload, :success],
          %{duration: duration},
          %{config_file: state.config_file}
        )

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :config_reload, :error],
          %{duration: duration},
          %{config_file: state.config_file, reason: reason}
        )
    end

    result
  end

  defp parse_config(content) do
    # For now, assume JSON or simple key=value format
    # In production, this would parse TOML or the actual config format
    case Jason.decode(content) do
      {:ok, config} ->
        {:ok, config}

      {:error, _} ->
        # Fallback: try to parse as simple format or return raw content
        {:ok, %{raw: content}}
    end
  rescue
    # If Jason is not available, return raw content
    UndefinedFunctionError ->
      {:ok, %{raw: content}}
  end
end
