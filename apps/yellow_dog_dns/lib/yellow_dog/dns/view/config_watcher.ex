defmodule YellowDog.Dns.View.ConfigWatcher do
  @moduledoc """
  File system watcher for DNS view configuration files.

  Monitors the view configuration file for changes and triggers hot-reload
  of views in the DNS handler. Provides debouncing to avoid excessive
  reloads during rapid file changes (e.g., editor saves).

  ## Features

  - File system watching using `FileSystem`
  - Debounced reload (default 300ms)
  - Automatic reload on file changes
  - Telemetry events for reload success/failure
  - Manual reload trigger via GenServer call

  ## Configuration

      config :yellow_dog_dns,
        views_config_path: "config/views.toml",
        hot_reload_enabled: true,
        reload_debounce_ms: 300

  ## Usage

      # Start watcher (usually in supervision tree)
      {:ok, pid} = ConfigWatcher.start_link(
        config_path: "config/views.toml",
        handler_pid: handler_pid
      )

      # Manual reload trigger
      ConfigWatcher.reload(pid)

      # Stop watching
      ConfigWatcher.stop(pid)

  ## Telemetry Events

  - `[:yellow_dog, :dns, :view, :config_reload, :start]` - Reload started
  - `[:yellow_dog, :dns, :view, :config_reload, :success]` - Reload succeeded
  - `[:yellow_dog, :dns, :view, :config_reload, :error]` - Reload failed
  """

  use GenServer
  require Logger

  alias YellowDog.Telemetry
  alias YellowDog.Dns.View.Config, as: ViewConfig

  @default_debounce_ms 300

  # Client API

  @doc """
  Starts the configuration watcher.

  ## Options

  - `:config_path` - Path to views TOML configuration file (required)
  - `:handler_pid` - PID of DNS handler to notify (required if reload_callback not provided)
  - `:reload_callback` - Function called on reload: `fun(views) -> :ok | {:error, reason}` (optional)
  - `:debounce_ms` - Debounce delay in milliseconds (default: #{@default_debounce_ms})
  - `:name` - GenServer name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Manually trigger a configuration reload.

  Returns `:ok` if reload was successfully triggered, or `{:error, reason}` if reload failed.
  """
  @spec reload(GenServer.server()) :: :ok | {:error, term()}
  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload)
  end

  @doc """
  Stop the configuration watcher.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__) do
    GenServer.stop(server, :normal)
  end

  @doc """
  Get current watcher status.

  Returns a map with watcher state information:
  - `:config_path` - Path being watched
  - `:watching` - Whether file watching is active
  - `:last_reload` - Timestamp of last reload attempt
  - `:reload_count` - Number of successful reloads
  - `:error_count` - Number of failed reload attempts
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    handler_pid = Keyword.get(opts, :handler_pid)
    reload_callback = Keyword.get(opts, :reload_callback)
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)

    # Validate that we have a way to reload
    cond do
      reload_callback != nil -> :ok
      handler_pid != nil -> :ok
      true -> raise ArgumentError, "Either :handler_pid or :reload_callback must be provided"
    end

    # Start file system watcher
    dir = Path.dirname(config_path)
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [dir])
    FileSystem.subscribe(watcher_pid)

    state = %{
      config_path: config_path,
      handler_pid: handler_pid,
      reload_callback: reload_callback,
      debounce_ms: debounce_ms,
      watcher_pid: watcher_pid,
      watching: true,
      debounce_timer: nil,
      last_reload: nil,
      reload_count: 0,
      error_count: 0
    }

    Telemetry.info("ConfigWatcher started", %{config_path: config_path})

    {:ok, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    # Manual reload is immediate (operator explicitly requesting)
    case perform_reload(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      config_path: state.config_path,
      watching: state.watching,
      last_reload: state.last_reload,
      reload_count: state.reload_count,
      error_count: state.error_count
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:file_event, watcher_pid, {path, events}}, %{watcher_pid: watcher_pid} = state) do
    # Check if this is our config file
    if Path.absname(path) == Path.absname(state.config_path) do
      # File was modified or created
      if :modified in events or :created in events do
        handle_file_change(state)
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, watcher_pid, :stop}, %{watcher_pid: watcher_pid} = state) do
    Telemetry.warning("File watcher stopped", %{config_path: state.config_path})
    {:noreply, %{state | watching: false}}
  end

  @impl true
  def handle_info(:debounce_reload, state) do
    # Debounce timer fired, perform reload
    case perform_reload(state) do
      {:ok, new_state} ->
        {:noreply, %{new_state | debounce_timer: nil}}

      {:error, _reason, new_state} ->
        {:noreply, %{new_state | debounce_timer: nil}}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp handle_file_change(state) do
    # Cancel existing debounce timer if any
    if state.debounce_timer do
      Process.cancel_timer(state.debounce_timer)
    end

    # Start new debounce timer
    timer = Process.send_after(self(), :debounce_reload, state.debounce_ms)

    {:noreply, %{state | debounce_timer: timer}}
  end

  defp perform_reload(state) do
    start_time = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:yellow_dog, :dns, :view, :config_reload, :start],
      %{},
      %{config_path: state.config_path}
    )

    # Load new configuration
    case ViewConfig.load_file(state.config_path) do
      {:ok, views} ->
        # Attempt to apply new views
        case apply_views(state, views) do
          :ok ->
            duration = System.monotonic_time(:millisecond) - start_time

            :telemetry.execute(
              [:yellow_dog, :dns, :view, :config_reload, :success],
              %{duration_ms: duration},
              %{
                config_path: state.config_path,
                view_count: length(views),
                view_names: Enum.map(views, & &1.name)
              }
            )

            Telemetry.info("Views reloaded successfully", %{
              duration_ms: duration,
              view_count: length(views)
            })

            new_state = %{
              state
              | last_reload: DateTime.utc_now(),
                reload_count: state.reload_count + 1
            }

            {:ok, new_state}

          {:error, reason} ->
            duration = System.monotonic_time(:millisecond) - start_time

            :telemetry.execute(
              [:yellow_dog, :dns, :view, :config_reload, :error],
              %{duration_ms: duration},
              %{
                config_path: state.config_path,
                reason: inspect(reason)
              }
            )

            Telemetry.error("Failed to apply new views", %{
              reason: inspect(reason),
              duration_ms: duration
            })

            new_state = %{state | error_count: state.error_count + 1}
            {:error, reason, new_state}
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:yellow_dog, :dns, :view, :config_reload, :error],
          %{duration_ms: duration},
          %{
            config_path: state.config_path,
            reason: inspect(reason)
          }
        )

        Telemetry.error("Failed to load view configuration", %{
          reason: inspect(reason),
          config_path: state.config_path,
          duration_ms: duration
        })

        new_state = %{state | error_count: state.error_count + 1}
        {:error, reason, new_state}
    end
  end

  defp apply_views(state, views) do
    cond do
      state.reload_callback != nil ->
        # Use custom reload callback
        state.reload_callback.(views)

      state.handler_pid != nil ->
        # Send reload message to handler
        try do
          GenServer.call(state.handler_pid, {:reload_views, views}, 5000)
        catch
          :exit, reason -> {:error, {:handler_call_failed, reason}}
        end

      true ->
        {:error, :no_reload_mechanism}
    end
  end
end
