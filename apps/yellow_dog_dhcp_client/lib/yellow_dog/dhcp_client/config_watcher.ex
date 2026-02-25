defmodule YellowDog.DhcpClient.ConfigWatcher do
  @moduledoc """
  Watches TOML configuration files for changes and reconciles running
  DHCP client interface supervisors.

  On config change, the watcher compares the current set of configured
  interfaces against the running set and:

  - Starts an `InterfaceSupervisor` for newly added interfaces
  - Stops the `InterfaceSupervisor` for removed interfaces
  - Restarts the `InterfaceSupervisor` for interfaces whose config changed

  Uses `file_system` to monitor the config directory. Changes are debounced
  to avoid reacting to intermediate file states during atomic writes.
  """

  use GenServer

  alias YellowDog.DhcpClient.Config

  require Logger

  @debounce_ms 1_500

  ## Client API

  @doc """
  Starts the ConfigWatcher.

  ## Options

  - `:config_file` - Path to the TOML config file to watch. Falls back to
    `YellowDog.DhcpClient.Config.config_file_path/0`.
  - `:debounce_ms` - Debounce interval in milliseconds (default: #{@debounce_ms}).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers a configuration reload and reconciliation.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Returns the current watcher status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    config_file = Keyword.get(opts, :config_file) || Config.config_file_path()
    debounce_ms = Keyword.get(opts, :debounce_ms, @debounce_ms)

    state = %{
      config_file: config_file,
      debounce_ms: debounce_ms,
      debounce_timer: nil,
      watcher_pid: nil,
      last_config: %{},
      reload_count: 0,
      last_reload_at: nil
    }

    state = maybe_start_watcher(state)

    # Perform initial reconciliation after a short delay to let the supervision
    # tree finish starting.
    Process.send_after(self(), :initial_reconcile, 100)

    {:ok, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case do_reconcile(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        Logger.warning("DHCP client config reload failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      config_file: state.config_file,
      watching: state.watcher_pid != nil,
      reload_count: state.reload_count,
      last_reload_at: state.last_reload_at,
      interfaces: Map.keys(state.last_config)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:initial_reconcile, state) do
    case do_reconcile(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    if matches_config_file?(path, state.config_file) and should_reload?(events) do
      # Cancel any pending debounce timer
      if state.debounce_timer, do: Process.cancel_timer(state.debounce_timer)

      timer = Process.send_after(self(), :debounced_reload, state.debounce_ms)

      :telemetry.execute(
        [:yellow_dog, :dhcp_client, :config_watcher, :change_detected],
        %{count: 1},
        %{config_file: state.config_file}
      )

      {:noreply, %{state | debounce_timer: timer}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("DHCP client config watcher: file system watcher stopped, attempting restart")
    new_state = maybe_start_watcher(%{state | watcher_pid: nil})
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:debounced_reload, state) do
    state = %{state | debounce_timer: nil}

    case do_reconcile(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private functions

  defp maybe_start_watcher(%{config_file: nil} = state) do
    Logger.debug("DHCP client config watcher: no config file path, watching disabled")
    state
  end

  defp maybe_start_watcher(%{config_file: config_file} = state) do
    watch_dir = Path.dirname(config_file)

    if File.dir?(watch_dir) do
      case FileSystem.start_link(dirs: [watch_dir], name: __MODULE__.FileSystemWatcher) do
        {:ok, pid} ->
          FileSystem.subscribe(__MODULE__.FileSystemWatcher)

          :telemetry.execute(
            [:yellow_dog, :dhcp_client, :config_watcher, :started],
            %{count: 1},
            %{config_file: config_file}
          )

          %{state | watcher_pid: pid}

        {:error, reason} ->
          Logger.warning(
            "DHCP client config watcher: failed to start file watcher: #{inspect(reason)}"
          )

          state
      end
    else
      Logger.debug(
        "DHCP client config watcher: directory #{watch_dir} does not exist, watching disabled"
      )

      state
    end
  end

  defp do_reconcile(state) do
    new_config = Config.load_all()
    old_config = state.last_config

    old_interfaces = Map.keys(old_config) |> MapSet.new()
    new_interfaces = Map.keys(new_config) |> MapSet.new()

    added = MapSet.difference(new_interfaces, old_interfaces)
    removed = MapSet.difference(old_interfaces, new_interfaces)

    changed =
      MapSet.intersection(old_interfaces, new_interfaces)
      |> Enum.filter(fn iface -> Map.get(old_config, iface) != Map.get(new_config, iface) end)
      |> MapSet.new()

    # Stop removed and changed interfaces
    for iface <- MapSet.union(removed, changed) do
      stop_interface(iface)
    end

    # Start added and changed interfaces
    for iface <- MapSet.union(added, changed) do
      iface_config = Map.fetch!(new_config, iface)
      start_interface(iface, iface_config)
    end

    if MapSet.size(added) > 0 or MapSet.size(removed) > 0 or MapSet.size(changed) > 0 do
      Logger.info(
        "DHCP client config reconciled: " <>
          "added=#{inspect(MapSet.to_list(added))} " <>
          "removed=#{inspect(MapSet.to_list(removed))} " <>
          "changed=#{inspect(MapSet.to_list(changed))}"
      )

      :telemetry.execute(
        [:yellow_dog, :dhcp_client, :config_watcher, :reconciled],
        %{
          added: MapSet.size(added),
          removed: MapSet.size(removed),
          changed: MapSet.size(changed)
        },
        %{interfaces: Map.keys(new_config)}
      )
    end

    new_state = %{
      state
      | last_config: new_config,
        reload_count: state.reload_count + 1,
        last_reload_at: DateTime.utc_now()
    }

    {:ok, new_state}
  rescue
    e ->
      Logger.warning("DHCP client config reconciliation failed: #{Exception.message(e)}")
      {:error, {:reconcile_failed, Exception.message(e)}}
  end

  defp start_interface(interface, config) do
    opts = [config: config]
    opts = if config[:mac], do: Keyword.put(opts, :mac, config[:mac]), else: opts

    case YellowDog.DhcpClient.start_interface(interface, opts) do
      {:ok, _pid} ->
        Logger.info("DHCP client started for interface #{interface}")
        :ok

      {:error, :already_started} ->
        Logger.debug("DHCP client already running for interface #{interface}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "DHCP client failed to start for interface #{interface}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp stop_interface(interface) do
    case YellowDog.DhcpClient.stop_interface(interface) do
      :ok ->
        Logger.info("DHCP client stopped for interface #{interface}")
        :ok

      {:error, :not_found} ->
        Logger.debug("DHCP client not running for interface #{interface}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "DHCP client failed to stop for interface #{interface}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp matches_config_file?(path, config_file) when is_binary(config_file) do
    Path.expand(path) == Path.expand(config_file)
  end

  defp matches_config_file?(_, _), do: false

  defp should_reload?(events) do
    Enum.any?(events, fn event -> event in [:modified, :created, :renamed] end)
  end
end
