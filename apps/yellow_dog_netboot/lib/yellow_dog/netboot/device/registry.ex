defmodule YellowDog.Netboot.Device.Registry do
  @moduledoc """
  ETS-backed device registry with PubSub broadcasting.

  Tracks all netboot devices and their lifecycle states.
  Broadcasts state changes on "netboot:devices" topic.
  Persists device state to TOML file with debounced writes.
  """

  use GenServer

  alias YellowDog.Netboot.Device
  alias YellowDog.Netboot.Device.Persistence

  @table __MODULE__
  @pubsub_topic "netboot:devices"
  @persist_delay_ms 5_000
  @default_persist_path "/var/lib/yellow_dog/netboot/devices.toml"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a new device or update an existing one."
  @spec register(String.t(), map()) :: {:ok, Device.t()} | {:error, term()}
  def register(mac, attrs \\ %{}) do
    GenServer.call(__MODULE__, {:register, mac, attrs})
  end

  @doc "Get a device by MAC address."
  @spec get(String.t()) :: {:ok, Device.t()} | {:error, :not_found}
  def get(mac) do
    normalized = Device.normalize_mac(mac)

    case :ets.lookup(@table, normalized) do
      [{^normalized, device}] -> {:ok, device}
      [] -> {:error, :not_found}
    end
  end

  @doc "Update a device's state with optional metadata."
  @spec update_state(String.t(), atom(), map()) :: {:ok, Device.t()} | {:error, term()}
  def update_state(mac, new_state, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:update_state, mac, new_state, metadata})
  end

  @doc "Assign a boot profile to a device."
  @spec assign_profile(String.t(), String.t()) :: {:ok, Device.t()} | {:error, term()}
  def assign_profile(mac, profile_id) do
    GenServer.call(__MODULE__, {:assign_profile, mac, profile_id})
  end

  @doc "Request a device reinstall."
  @spec request_reinstall(String.t()) :: {:ok, Device.t()} | {:error, term()}
  def request_reinstall(mac) do
    update_state(mac, :reinstall_requested)
  end

  @doc "Set or clear rescue mode on a device."
  @spec set_rescue_mode(String.t(), boolean()) :: {:ok, Device.t()} | {:error, term()}
  def set_rescue_mode(mac, enabled) do
    GenServer.call(__MODULE__, {:set_rescue_mode, mac, enabled})
  end

  @doc "Update a device's tags."
  @spec update_tags(String.t(), [String.t()]) :: {:ok, Device.t()} | {:error, term()}
  def update_tags(mac, tags) when is_list(tags) do
    GenServer.call(__MODULE__, {:update_tags, mac, tags})
  end

  @doc "Delete a device from the registry."
  @spec delete(String.t()) :: :ok
  def delete(mac) do
    GenServer.call(__MODULE__, {:delete, mac})
  end

  @doc "List all devices, optionally filtered."
  @spec list(keyword()) :: [Device.t()]
  def list(filters \\ []) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_mac, device} -> device end)
    |> apply_filters(filters)
  end

  @doc "Count devices by state."
  @spec count_by_state() :: map()
  def count_by_state do
    list()
    |> Enum.frequencies_by(& &1.state)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    config = Keyword.get(opts, :config, %{})
    persist_path = persist_path(config)

    load_persisted_devices(persist_path)

    {:ok, %{persist_path: persist_path, persist_timer: nil}}
  end

  @impl true
  def handle_call({:register, mac, attrs}, _from, state) do
    normalized = Device.normalize_mac(mac)

    device =
      case :ets.lookup(@table, normalized) do
        [{^normalized, existing}] ->
          %{existing | last_seen: DateTime.utc_now()}
          |> maybe_update_field(:hostname, Map.get(attrs, :hostname))
          |> maybe_update_field(:uuid, Map.get(attrs, :uuid))
          |> maybe_update_field(:arch, Map.get(attrs, :arch))
          |> maybe_update_field(:ip_address, Map.get(attrs, :ip_address))

        [] ->
          Device.new(mac, attrs)
      end

    :ets.insert(@table, {normalized, device})
    broadcast({:device_registered, device})
    {:reply, {:ok, device}, schedule_persist(state)}
  end

  @impl true
  def handle_call({:update_state, mac, new_state, metadata}, _from, state) do
    normalized = Device.normalize_mac(mac)

    case :ets.lookup(@table, normalized) do
      [{^normalized, device}] ->
        case Device.transition(device, new_state, metadata) do
          {:ok, updated} ->
            :ets.insert(@table, {normalized, updated})
            broadcast({:device_state_changed, updated})
            {:reply, {:ok, updated}, schedule_persist(state)}

          {:error, _} = err ->
            {:reply, err, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:assign_profile, mac, profile_id}, _from, state) do
    normalized = Device.normalize_mac(mac)

    case :ets.lookup(@table, normalized) do
      [{^normalized, device}] ->
        updated = %{device | profile_id: profile_id, last_seen: DateTime.utc_now()}
        :ets.insert(@table, {normalized, updated})
        broadcast({:device_profile_assigned, updated})
        {:reply, {:ok, updated}, schedule_persist(state)}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:set_rescue_mode, mac, enabled}, _from, state) do
    normalized = Device.normalize_mac(mac)

    case :ets.lookup(@table, normalized) do
      [{^normalized, device}] ->
        updated = %{device | rescue_mode: enabled, last_seen: DateTime.utc_now()}
        :ets.insert(@table, {normalized, updated})
        broadcast({:device_state_changed, updated})
        {:reply, {:ok, updated}, schedule_persist(state)}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update_tags, mac, tags}, _from, state) do
    normalized = Device.normalize_mac(mac)

    case :ets.lookup(@table, normalized) do
      [{^normalized, device}] ->
        updated = %{device | tags: tags, last_seen: DateTime.utc_now()}
        :ets.insert(@table, {normalized, updated})
        broadcast({:device_state_changed, updated})
        {:reply, {:ok, updated}, schedule_persist(state)}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete, mac}, _from, state) do
    normalized = Device.normalize_mac(mac)
    :ets.delete(@table, normalized)
    broadcast({:device_deleted, normalized})
    {:reply, :ok, schedule_persist(state)}
  end

  @impl true
  def handle_info(:persist, state) do
    persist_to_disk(state.persist_path)
    {:noreply, %{state | persist_timer: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp maybe_update_field(device, _field, nil), do: device
  defp maybe_update_field(device, field, value), do: Map.put(device, field, value)

  defp apply_filters(devices, []), do: devices

  defp apply_filters(devices, [{:state, state} | rest]) do
    devices
    |> Enum.filter(&(&1.state == state))
    |> apply_filters(rest)
  end

  defp apply_filters(devices, [{:profile_id, profile_id} | rest]) do
    devices
    |> Enum.filter(&(&1.profile_id == profile_id))
    |> apply_filters(rest)
  end

  defp apply_filters(devices, [{:arch, arch} | rest]) do
    devices
    |> Enum.filter(&(&1.arch == arch))
    |> apply_filters(rest)
  end

  defp apply_filters(devices, [{:tag, tag} | rest]) do
    devices
    |> Enum.filter(&(tag in &1.tags))
    |> apply_filters(rest)
  end

  defp apply_filters(devices, [_ | rest]), do: apply_filters(devices, rest)

  defp schedule_persist(state) do
    if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
    timer = Process.send_after(self(), :persist, @persist_delay_ms)
    %{state | persist_timer: timer}
  end

  defp persist_to_disk(path) do
    devices = list()
    Persistence.save(path, devices)
  rescue
    _ -> :ok
  end

  defp load_persisted_devices(path) do
    case Persistence.load(path) do
      {:ok, devices} ->
        Enum.each(devices, fn device ->
          :ets.insert(@table, {device.mac, device})
        end)

      {:error, _} ->
        :ok
    end
  end

  defp persist_path(config) when is_map(config) do
    Map.get(config, :persist_path, @default_persist_path)
  end

  defp persist_path(_), do: @default_persist_path

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(
      YellowDog.Console.PubSub,
      @pubsub_topic,
      message
    )
  rescue
    _ -> :ok
  end
end
