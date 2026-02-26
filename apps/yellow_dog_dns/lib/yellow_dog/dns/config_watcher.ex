defmodule YellowDog.Dns.ConfigWatcher do
  @moduledoc """
  Watches DNS configuration files for changes and triggers hot reloads.

  Uses polling-based file change detection (checking mtimes) with
  configurable check interval and debouncing to avoid rapid reloads.

  ## Watched Files

  - `views.toml` - View definitions with ACLs
  - `acls.toml` - Named ACL definitions
  - Zone files under `zones/` directories

  ## Reload Behavior

  1. Detect file modification via mtime comparison
  2. Debounce rapid changes (configurable, default 500ms)
  3. Parse and validate new configuration
  4. If valid, apply changes atomically
  5. If invalid, log error and keep current config
  6. Emit telemetry event with reload status
  """

  use GenServer

  require Logger

  alias YellowDog.Telemetry
  alias YellowDog.Dns.ConfigPersistence

  @default_interval 5_000
  @default_debounce 500

  defstruct [
    :data_path,
    :check_interval,
    :debounce_ms,
    :timer_ref,
    :debounce_ref,
    mtimes: %{},
    last_reload: nil,
    reload_count: 0,
    error_count: 0,
    enabled: true
  ]

  # Client API

  @doc """
  Starts the ConfigWatcher.

  ## Options

  - `:data_path` - Path to DNS data directory (default: from ConfigPersistence)
  - `:check_interval` - Milliseconds between file checks (default: 5000)
  - `:debounce_ms` - Debounce window for rapid changes (default: 500)
  - `:enabled` - Whether watching is enabled (default: true)
  - `:name` - GenServer registration name (default: __MODULE__)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Manually triggers a configuration reload.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload, do: reload(__MODULE__)

  @spec reload(GenServer.server()) :: :ok | {:error, term()}
  def reload(server) do
    GenServer.call(server, :reload)
  end

  @doc """
  Reloads only views configuration.
  """
  @spec reload_views() :: :ok | {:error, term()}
  def reload_views, do: reload_views(__MODULE__)

  @spec reload_views(GenServer.server()) :: :ok | {:error, term()}
  def reload_views(server) do
    GenServer.call(server, :reload_views)
  end

  @doc """
  Reloads only ACLs configuration.
  """
  @spec reload_acls() :: :ok | {:error, term()}
  def reload_acls, do: reload_acls(__MODULE__)

  @spec reload_acls(GenServer.server()) :: :ok | {:error, term()}
  def reload_acls(server) do
    GenServer.call(server, :reload_acls)
  end

  @doc """
  Returns watcher statistics.
  """
  @spec stats() :: map()
  def stats, do: stats(__MODULE__)

  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @doc """
  Enables or disables the file watcher.
  """
  @spec set_enabled(boolean()) :: :ok
  def set_enabled(enabled), do: set_enabled(__MODULE__, enabled)

  @spec set_enabled(GenServer.server(), boolean()) :: :ok
  def set_enabled(server, enabled) do
    GenServer.call(server, {:set_enabled, enabled})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    data_path = Keyword.get(opts, :data_path, ConfigPersistence.default_data_path())
    check_interval = Keyword.get(opts, :check_interval, @default_interval)
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce)
    enabled = Keyword.get(opts, :enabled, true)

    state = %__MODULE__{
      data_path: data_path,
      check_interval: check_interval,
      debounce_ms: debounce_ms,
      enabled: enabled
    }

    # Record initial file mtimes
    state = %{state | mtimes: scan_mtimes(data_path)}

    # Schedule first check
    timer_ref =
      if enabled do
        Process.send_after(self(), :check_files, check_interval)
      else
        nil
      end

    Telemetry.info("ConfigWatcher started", %{
      data_path: data_path,
      interval: check_interval,
      enabled: enabled,
      watched_files: map_size(state.mtimes)
    })

    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case do_reload(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, _reason} = error ->
        {:reply, error, %{state | error_count: state.error_count + 1}}
    end
  end

  @impl true
  def handle_call(:reload_views, _from, state) do
    result = do_reload_views(state.data_path)

    state =
      case result do
        :ok -> %{state | last_reload: DateTime.utc_now(), reload_count: state.reload_count + 1}
        {:error, _} -> %{state | error_count: state.error_count + 1}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:reload_acls, _from, state) do
    result = do_reload_acls(state.data_path)

    state =
      case result do
        :ok -> %{state | last_reload: DateTime.utc_now(), reload_count: state.reload_count + 1}
        {:error, _} -> %{state | error_count: state.error_count + 1}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      data_path: state.data_path,
      check_interval: state.check_interval,
      debounce_ms: state.debounce_ms,
      enabled: state.enabled,
      watched_files: map_size(state.mtimes),
      last_reload: state.last_reload,
      reload_count: state.reload_count,
      error_count: state.error_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    # Cancel existing timer if disabling
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    timer_ref =
      if enabled do
        Process.send_after(self(), :check_files, state.check_interval)
      else
        nil
      end

    {:reply, :ok, %{state | enabled: enabled, timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:check_files, %{enabled: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_files, state) do
    new_mtimes = scan_mtimes(state.data_path)
    changed = detect_changes(state.mtimes, new_mtimes)

    state =
      if changed != [] do
        # Cancel any pending debounce
        if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)

        # Schedule debounced reload
        debounce_ref = Process.send_after(self(), {:debounced_reload, changed}, state.debounce_ms)
        %{state | mtimes: new_mtimes, debounce_ref: debounce_ref}
      else
        %{state | mtimes: new_mtimes}
      end

    # Schedule next check
    timer_ref = Process.send_after(self(), :check_files, state.check_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info({:debounced_reload, changed_files}, state) do
    Telemetry.info("Config files changed, reloading", %{
      changed: length(changed_files),
      files: Enum.map(changed_files, &Path.basename/1)
    })

    state =
      case do_selective_reload(state, changed_files) do
        {:ok, new_state} -> new_state
        {:error, _reason} -> %{state | error_count: state.error_count + 1}
      end

    :telemetry.execute(
      [:yellow_dog, :dns, :config, :reloaded],
      %{count: 1},
      %{changed_files: changed_files, success: state.error_count == 0}
    )

    {:noreply, %{state | debounce_ref: nil}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp scan_mtimes(data_path) do
    if File.dir?(data_path) do
      files = find_config_files(data_path)

      Map.new(files, fn file ->
        mtime =
          case File.stat(file) do
            {:ok, %{mtime: mtime}} -> mtime
            {:error, _} -> nil
          end

        {file, mtime}
      end)
    else
      %{}
    end
  end

  defp find_config_files(data_path) do
    toml_files =
      Path.join(data_path, "**/*.toml")
      |> Path.wildcard()

    zone_files =
      Path.join(data_path, "**/*.zone")
      |> Path.wildcard()

    toml_files ++ zone_files
  end

  defp detect_changes(old_mtimes, new_mtimes) do
    # Find files that are new or have different mtimes
    new_or_changed =
      Enum.filter(new_mtimes, fn {file, mtime} ->
        case Map.get(old_mtimes, file) do
          nil -> true
          ^mtime -> false
          _ -> true
        end
      end)
      |> Enum.map(&elem(&1, 0))

    # Find deleted files
    deleted =
      Enum.filter(old_mtimes, fn {file, _mtime} ->
        not Map.has_key?(new_mtimes, file)
      end)
      |> Enum.map(&elem(&1, 0))

    new_or_changed ++ deleted
  end

  defp do_reload(state) do
    with :ok <- do_reload_views(state.data_path),
         :ok <- do_reload_acls(state.data_path) do
      new_state = %{
        state
        | last_reload: DateTime.utc_now(),
          reload_count: state.reload_count + 1,
          mtimes: scan_mtimes(state.data_path)
      }

      {:ok, new_state}
    end
  end

  defp do_selective_reload(state, changed_files) do
    # Determine what to reload based on which files changed
    reload_views? = Enum.any?(changed_files, &String.ends_with?(&1, "views.toml"))
    reload_acls? = Enum.any?(changed_files, &String.ends_with?(&1, "acls.toml"))

    results = []

    results =
      if reload_views? do
        [do_reload_views(state.data_path) | results]
      else
        results
      end

    results =
      if reload_acls? do
        [do_reload_acls(state.data_path) | results]
      else
        results
      end

    # Reload individual zone files
    zone_files =
      changed_files
      |> Enum.filter(&(String.ends_with?(&1, ".zone") or String.contains?(&1, "zones/")))

    results =
      if zone_files != [] do
        [do_reload_zones(state.data_path, zone_files) | results]
      else
        results
      end

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok,
       %{
         state
         | last_reload: DateTime.utc_now(),
           reload_count: state.reload_count + 1
       }}
    else
      {:error, {:reload_errors, errors}}
    end
  end

  defp do_reload_views(data_path) do
    try do
      YellowDog.Dns.ViewManager.load_config(data_path)
    rescue
      e in [ArgumentError, RuntimeError, MatchError, FunctionClauseError, KeyError] ->
        Telemetry.error("Failed to reload views", %{error: Exception.message(e)})
        {:error, {:reload_failed, Exception.message(e)}}
    catch
      :exit, reason ->
        Telemetry.error("Failed to reload views", %{error: inspect(reason)})
        {:error, {:reload_failed, reason}}
    end
  end

  defp do_reload_acls(_data_path) do
    try do
      YellowDog.Dns.AclRegistry.reload()
    rescue
      e in [ArgumentError, RuntimeError, MatchError, FunctionClauseError, KeyError] ->
        Telemetry.error("Failed to reload ACLs", %{error: Exception.message(e)})
        {:error, {:reload_failed, Exception.message(e)}}
    catch
      :exit, reason ->
        Telemetry.error("Failed to reload ACLs", %{error: inspect(reason)})
        {:error, {:reload_failed, reason}}
    end
  end

  defp do_reload_zones(_data_path, zone_files) do
    # Reload changed zone files by finding the corresponding zone processes
    results =
      Enum.map(zone_files, fn file ->
        try do
          # Extract view and zone name from file path
          case parse_zone_file_path(file) do
            {:ok, view_name, zone_name} ->
              case YellowDog.Dns.ZoneController.find_zone(view_name, :auth, zone_name) do
                {:ok, pid} ->
                  YellowDog.Dns.Zone.Auth.reload(pid, zone_file: file)

                :error ->
                  # Zone not running, skip
                  :ok
              end

            :error ->
              :ok
          end
        rescue
          e in [ArgumentError, RuntimeError, MatchError, FunctionClauseError, KeyError] ->
            {:error, {file, Exception.message(e)}}
        catch
          :exit, reason -> {:error, {file, reason}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      :ok
    else
      {:error, {:zone_reload_errors, errors}}
    end
  end

  defp parse_zone_file_path(file) do
    # Expected patterns:
    # .../views/{view_name}/zones/{zone_name}.zone
    # .../views/{view_name}/zones/{zone_name}.toml
    parts = Path.split(file)

    case find_view_zone_in_path(parts) do
      {view, zone} -> {:ok, view, zone}
      nil -> :error
    end
  end

  defp find_view_zone_in_path([]), do: nil

  defp find_view_zone_in_path(["views", view_name, "zones", zone_file | _]) do
    zone_name =
      zone_file
      |> Path.rootname()
      |> Path.rootname()

    {view_name, zone_name}
  end

  defp find_view_zone_in_path([_ | rest]) do
    find_view_zone_in_path(rest)
  end
end
