defmodule YellowDog.Netboot.Device.Registry do
  @moduledoc """
  Durable device registry keyed by normalized MAC address.

  Every mutation is serialized through this owner and commits a complete
  managed snapshot before replacing ETS state and broadcasting the change.
  """

  use GenServer
  use YellowDog.Data.Collection

  alias YellowDog.Data.Store
  alias YellowDog.Netboot.Device
  alias YellowDog.Netboot.Device.Persistence

  defcollection(:netboot_devices,
    key_field: :mac,
    adapter: YellowDog.Data.Store.Ets
  )

  @pubsub_topic "netboot:devices"
  @default_legacy_path "/var/lib/yellow_dog/netboot/devices.toml"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a new device or update runtime observations for an existing MAC."
  @spec register(String.t(), map()) :: {:ok, Device.t()} | {:error, term()}
  def register(mac, attrs \\ %{}) do
    GenServer.call(__MODULE__, {:register, mac, attrs})
  end

  @doc "Get a device by MAC address."
  @spec get(String.t()) :: {:ok, Device.t()} | {:error, :not_found}
  def get(mac) do
    GenServer.call(__MODULE__, {:get, Device.normalize_mac(mac)})
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

  @doc "Delete a device by MAC."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(mac) do
    GenServer.call(__MODULE__, {:delete, mac})
  end

  @doc "List all devices, optionally filtered."
  @spec list(keyword()) :: [Device.t()]
  def list(filters \\ []) do
    GenServer.call(__MODULE__, {:list, filters})
  end

  @doc "Count devices by state."
  @spec count_by_state() :: map()
  def count_by_state do
    list()
    |> Enum.frequencies_by(& &1.state)
  end

  @doc "Return a serialized complete snapshot for the server control adapter."
  @spec control_snapshot() :: {:ok, [Device.t()]}
  def control_snapshot do
    GenServer.call(__MODULE__, :control_snapshot)
  end

  @doc "Create or update a control-owned device identified by immutable UUID."
  @spec control_put_device(String.t(), String.t(), String.t()) ::
          {:ok, [Device.t()], [Device.t()]} | {:error, term()}
  def control_put_device(device_id, profile_id, mac) do
    GenServer.call(__MODULE__, {:control_put_device, device_id, profile_id, mac})
  end

  @doc "Delete a control-owned device by UUID."
  @spec control_delete_device(String.t()) ::
          {:ok, [Device.t()], [Device.t()]} | {:error, term()}
  def control_delete_device(device_id) do
    GenServer.call(__MODULE__, {:control_delete_device, device_id})
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, %{})
    managed_path = managed_path(opts, config)
    legacy_path = legacy_path(opts, config)

    state = %{
      managed_path: managed_path,
      legacy_path: legacy_path,
      persistence_opts:
        Keyword.get(opts, :storage_opts, Keyword.get(opts, :persistence_opts, [])),
      persist_hook: Keyword.get(opts, :persist_hook),
      apply_hook: Keyword.get(opts, :apply_hook),
      broadcast_hook: Keyword.get(opts, :broadcast_hook)
    }

    with {:ok, store} <- Store.init(collection(), []),
         {:ok, snapshot} <-
           load_startup_snapshot(managed_path, legacy_path, state.persistence_opts),
         :ok <- replace_snapshot(store, snapshot.devices) do
      state =
        state
        |> Map.put(:store, store)
        |> put_runtime_snapshot(snapshot)

      {:ok, state}
    else
      {:error, reason} -> {:stop, {:device_registry_init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:get, mac}, _from, state) do
    {:reply, get_from_state(state, mac), state}
  end

  @impl true
  def handle_call({:list, filters}, _from, state) do
    {:reply, apply_filters(state.devices, filters), state}
  end

  @impl true
  def handle_call(:control_snapshot, _from, state) do
    {:reply, {:ok, snapshot(state)}, state}
  end

  @impl true
  def handle_call({:register, mac, attrs}, _from, state) when is_map(attrs) do
    normalized = Device.normalize_mac(mac)
    prior = state_snapshot(state)

    case registered_device(state, normalized, attrs) do
      {:ok, device} ->
        candidate =
          prior
          |> Map.put(:devices, replace_by_mac(prior.devices, device))
          |> clear_tombstones_for_mac(device.mac)

        case commit(state, prior, candidate, {:device_registered, device}) do
          {:ok, resulting, new_state} ->
            {:reply, {:ok, find_by_mac!(resulting, device.mac)}, new_state}

          {:error, reason, new_state} ->
            {:reply, {:error, reason}, new_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:register, _mac, _attrs}, _from, state) do
    {:reply, {:error, :invalid_snapshot}, state}
  end

  @impl true
  def handle_call({:update_state, mac, new_state, metadata}, _from, state) do
    mutate_by_mac(
      state,
      mac,
      fn device ->
        Device.transition(device, new_state, metadata)
      end,
      :device_state_changed
    )
  end

  @impl true
  def handle_call({:assign_profile, mac, profile_id}, _from, state) do
    mutate_by_mac(
      state,
      mac,
      fn device ->
        {:ok, %{device | profile_id: profile_id, last_seen: DateTime.utc_now()}}
      end,
      :device_profile_assigned
    )
  end

  @impl true
  def handle_call({:set_rescue_mode, mac, enabled}, _from, state) do
    mutate_by_mac(
      state,
      mac,
      fn device ->
        {:ok, %{device | rescue_mode: enabled, last_seen: DateTime.utc_now()}}
      end,
      :device_state_changed
    )
  end

  @impl true
  def handle_call({:update_tags, mac, tags}, _from, state) do
    mutate_by_mac(
      state,
      mac,
      fn device ->
        {:ok, %{device | tags: tags, last_seen: DateTime.utc_now()}}
      end,
      :device_state_changed
    )
  end

  @impl true
  def handle_call({:delete, mac}, _from, state) do
    normalized = Device.normalize_mac(mac)
    prior = state_snapshot(state)
    candidate = delete_by_mac(prior, normalized)

    case commit(state, prior, candidate, {:device_deleted, normalized}) do
      {:ok, _resulting, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:control_put_device, device_id, profile_id, mac}, _from, state) do
    prior = state_snapshot(state)

    with :ok <- validate_control_fields(device_id, profile_id, mac),
         {:ok, device} <- control_device(prior.devices, device_id, profile_id, mac) do
      previous = Enum.find(prior.devices, &(&1.uuid == device_id))
      candidate = control_put_candidate(prior, previous, device)

      case commit(state, prior, candidate, {:device_registered, device}) do
        {:ok, resulting, new_state} ->
          {:reply, {:ok, prior.devices, resulting}, new_state}

        {:error, reason, new_state} ->
          {:reply, {:error, reason}, new_state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:control_delete_device, device_id}, _from, state) do
    prior = state_snapshot(state)

    case Enum.find(prior.devices, &(&1.uuid == device_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      device ->
        candidate = delete_device(prior, device)

        case commit(state, prior, candidate, {:device_deleted, device.mac}) do
          {:ok, resulting, new_state} ->
            {:reply, {:ok, prior.devices, resulting}, new_state}

          {:error, reason, new_state} ->
            {:reply, {:error, reason}, new_state}
        end
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp mutate_by_mac(state, mac, update, event) do
    normalized = Device.normalize_mac(mac)
    prior = state_snapshot(state)

    with {:ok, device} <- get_from_state(state, normalized),
         {:ok, updated} <- update.(device) do
      candidate = Map.put(prior, :devices, replace_by_mac(prior.devices, updated))

      case commit(state, prior, candidate, {event, updated}) do
        {:ok, resulting, new_state} ->
          {:reply, {:ok, find_by_mac!(resulting, updated.mac)}, new_state}

        {:error, reason, new_state} ->
          {:reply, {:error, reason}, new_state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp registered_device(state, normalized, attrs) do
    case get_from_state(state, normalized) do
      {:ok, existing} ->
        with :ok <- validate_uuid_update(existing.uuid, Map.get(attrs, :uuid)) do
          arch = normalized_arch(Map.get(attrs, :arch))

          device =
            %{existing | last_seen: DateTime.utc_now()}
            |> maybe_update_field(:hostname, Map.get(attrs, :hostname))
            |> maybe_update_field(:uuid, Map.get(attrs, :uuid))
            |> maybe_update_field(:arch, arch)
            |> maybe_update_field(:ip_address, Map.get(attrs, :ip_address))
            |> maybe_update_field(:hardware_info, Map.get(attrs, :hardware_info))

          {:ok, device}
        end

      {:error, :not_found} ->
        {:ok, Device.new(normalized, attrs)}
    end
  end

  defp validate_uuid_update(nil, _incoming), do: :ok
  defp validate_uuid_update(_existing, nil), do: :ok
  defp validate_uuid_update(existing, existing), do: :ok
  defp validate_uuid_update(_existing, _incoming), do: {:error, :immutable_device_id}

  defp normalized_arch(nil), do: nil
  defp normalized_arch(arch), do: Device.new("00:00:00:00:00:00", %{arch: arch}).arch

  defp control_device(devices, device_id, profile_id, mac) do
    normalized = Device.normalize_mac(mac)

    case Enum.find(devices, &(&1.uuid == device_id)) do
      nil ->
        case Enum.find(devices, &(&1.mac == normalized)) do
          nil -> {:ok, Device.new(normalized, %{uuid: device_id, profile_id: profile_id})}
          _owner -> {:error, :conflict}
        end

      existing ->
        case Enum.find(devices, &(&1.mac == normalized and &1.uuid != device_id)) do
          nil -> {:ok, %{existing | mac: normalized, profile_id: profile_id}}
          _owner -> {:error, :conflict}
        end
    end
  end

  defp validate_control_fields(device_id, profile_id, mac)
       when is_binary(device_id) and device_id != "" and is_binary(profile_id) and
              profile_id != "" and is_binary(mac) do
    normalized = Device.normalize_mac(mac)

    if Device.valid_mac?(normalized) do
      :ok
    else
      {:error, :invalid_snapshot}
    end
  end

  defp validate_control_fields(_device_id, _profile_id, _mac),
    do: {:error, :invalid_snapshot}

  defp commit(state, prior, candidate, event) do
    candidate = stable_state(candidate)

    with :ok <- validate_candidate(candidate),
         :ok <- persist_snapshot(state, candidate),
         :ok <- apply_snapshot(state, candidate.devices) do
      new_state = put_runtime_snapshot(state, candidate)
      broadcast(new_state, event)
      {:ok, candidate.devices, new_state}
    else
      {:error, :invalid_snapshot} -> {:error, :invalid_snapshot, state}
      {:error, :conflict} -> {:error, :conflict, state}
      {:error, :persistence_failed} -> {:error, :persistence_failed, state}
      {:error, :apply_failed} -> rollback(state, prior, candidate)
    end
  end

  defp rollback(state, prior, candidate) do
    case persist_snapshot(state, prior) do
      :ok ->
        restored_state = put_runtime_snapshot(state, prior)

        case apply_snapshot(state, prior.devices) do
          :ok -> {:error, :apply_failed, restored_state}
          {:error, :apply_failed} -> {:error, :rollback_failed, restored_state}
        end

      {:error, :persistence_failed} ->
        {:error, :rollback_failed, put_runtime_snapshot(state, candidate)}
    end
  end

  defp persist_snapshot(state, snapshot) do
    result =
      case state.persist_hook do
        hook when is_function(hook, 3) ->
          safe_phase(fn -> hook.(state.managed_path, snapshot, state.persistence_opts) end)

        _other ->
          safe_phase(fn ->
            Persistence.save_state(state.managed_path, snapshot, state.persistence_opts)
          end)
      end

    case result do
      :ok -> :ok
      :error -> {:error, :persistence_failed}
    end
  end

  defp apply_snapshot(state, devices) do
    with :ok <- replace_snapshot(state.store, devices),
         :ok <- run_apply_hook(state.apply_hook, devices) do
      :ok
    else
      _other -> {:error, :apply_failed}
    end
  end

  defp replace_snapshot(store, devices) do
    safe_phase(fn ->
      existing_keys = store.table |> :ets.tab2list() |> Enum.map(&elem(&1, 0))
      candidate_keys = MapSet.new(devices, & &1.mac)

      true = :ets.insert(store.table, Enum.map(devices, &{&1.mac, &1}))

      Enum.each(existing_keys, fn key ->
        if not MapSet.member?(candidate_keys, key), do: :ets.delete(store.table, key)
      end)

      :ok
    end)
  end

  defp run_apply_hook(hook, devices) when is_function(hook, 1) do
    safe_phase(fn -> hook.(stable_snapshot(devices)) end)
  end

  defp run_apply_hook(_hook, _devices), do: :ok

  defp broadcast(%{broadcast_hook: hook}, event) when is_function(hook, 1) do
    _result = safe_phase(fn -> hook.(event) end)
    :ok
  end

  defp broadcast(_state, event) do
    Phoenix.PubSub.broadcast(
      YellowDog.Console.PubSub,
      @pubsub_topic,
      event
    )

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_phase(fun) do
    case fun.() do
      :ok -> :ok
      _other -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp load_startup_snapshot(managed_path, legacy_path, persistence_opts) do
    with {:ok, managed} <- Persistence.load_state(managed_path, persistence_opts) do
      legacy =
        case Persistence.load_legacy(legacy_path) do
          {:ok, devices} -> devices
          {:error, _reason} -> []
        end

      {:ok, merge_legacy_fallback(managed, legacy)}
    end
  end

  defp merge_legacy_fallback(%{devices: managed, tombstones: tombstones}, legacy) do
    devices =
      Enum.reduce(legacy, managed, fn device, devices ->
        if valid_fallback?(device, devices, tombstones), do: [device | devices], else: devices
      end)

    stable_state(%{devices: devices, tombstones: tombstones})
  end

  defp valid_fallback?(device, devices, tombstones) do
    Device.validate(device) == :ok and
      not tombstoned?(device, tombstones) and
      not Enum.any?(devices, fn existing ->
        existing.mac == device.mac or
          (not is_nil(existing.uuid) and existing.uuid == device.uuid)
      end)
  end

  defp validate_candidate(%{devices: devices, tombstones: tombstones} = candidate)
       when map_size(candidate) == 2 do
    with :ok <- validate_devices(devices),
         :ok <- validate_tombstones(tombstones) do
      :ok
    end
  end

  defp validate_candidate(_candidate), do: {:error, :invalid_snapshot}

  defp validate_devices(devices) when is_list(devices) do
    Enum.reduce_while(devices, {:ok, MapSet.new(), MapSet.new()}, fn device, {:ok, macs, uuids} ->
      cond do
        Device.validate(device) != :ok ->
          {:halt, {:error, :invalid_snapshot}}

        MapSet.member?(macs, device.mac) ->
          {:halt, {:error, :conflict}}

        not is_nil(device.uuid) and MapSet.member?(uuids, device.uuid) ->
          {:halt, {:error, :conflict}}

        true ->
          uuids = if is_nil(device.uuid), do: uuids, else: MapSet.put(uuids, device.uuid)
          {:cont, {:ok, MapSet.put(macs, device.mac), uuids}}
      end
    end)
    |> case do
      {:ok, _macs, _uuids} -> :ok
      error -> error
    end
  end

  defp validate_devices(_devices), do: {:error, :invalid_snapshot}

  defp validate_tombstones(tombstones) do
    case Persistence.validate_state(%{devices: [], tombstones: tombstones}) do
      :ok -> :ok
      {:error, :invalid_snapshot} -> {:error, :invalid_snapshot}
    end
  end

  defp snapshot(state), do: state.devices

  defp state_snapshot(state) do
    %{devices: state.devices, tombstones: state.tombstones}
  end

  defp stable_snapshot(devices), do: Enum.sort_by(devices, & &1.mac)

  defp stable_state(%{devices: devices, tombstones: tombstones}) do
    %{
      devices: stable_snapshot(devices),
      tombstones: Enum.sort_by(tombstones, &{&1.mac, &1.uuid || ""})
    }
  end

  defp put_runtime_snapshot(state, snapshot) do
    snapshot = stable_state(snapshot)

    state
    |> Map.put(:devices, snapshot.devices)
    |> Map.put(:devices_by_mac, Map.new(snapshot.devices, &{&1.mac, &1}))
    |> Map.put(:tombstones, snapshot.tombstones)
  end

  defp get_from_state(state, mac) do
    case Map.fetch(state.devices_by_mac, mac) do
      {:ok, device} -> {:ok, device}
      :error -> {:error, :not_found}
    end
  end

  defp delete_by_mac(snapshot, mac) do
    case Enum.find(snapshot.devices, &(&1.mac == mac)) do
      nil -> snapshot
      device -> delete_device(snapshot, device)
    end
  end

  defp delete_device(snapshot, device) do
    snapshot
    |> Map.put(:devices, Enum.reject(snapshot.devices, &(&1.mac == device.mac)))
    |> add_tombstone(device)
  end

  defp control_put_candidate(snapshot, previous, device) do
    snapshot
    |> Map.put(:devices, replace_by_uuid(snapshot.devices, device))
    |> maybe_add_rekey_tombstone(previous, device)
    |> clear_tombstones_for_mac(device.mac)
  end

  defp maybe_add_rekey_tombstone(snapshot, nil, _device), do: snapshot

  defp maybe_add_rekey_tombstone(snapshot, previous, device) do
    if previous.mac == device.mac, do: snapshot, else: add_tombstone(snapshot, previous)
  end

  defp add_tombstone(snapshot, device) do
    tombstone = %{uuid: device.uuid, mac: device.mac}

    Map.update!(snapshot, :tombstones, fn tombstones ->
      if tombstone in tombstones, do: tombstones, else: [tombstone | tombstones]
    end)
  end

  defp clear_tombstones_for_mac(snapshot, mac) do
    Map.update!(snapshot, :tombstones, &Enum.reject(&1, fn tombstone -> tombstone.mac == mac end))
  end

  defp tombstoned?(device, tombstones) do
    Enum.any?(tombstones, fn tombstone ->
      tombstone.mac == device.mac or
        (not is_nil(tombstone.uuid) and tombstone.uuid == device.uuid)
    end)
  end

  defp replace_by_mac(devices, device) do
    devices
    |> Enum.reject(&(&1.mac == device.mac))
    |> List.insert_at(-1, device)
  end

  defp replace_by_uuid(devices, device) do
    devices
    |> Enum.reject(&(&1.uuid == device.uuid))
    |> List.insert_at(-1, device)
  end

  defp find_by_mac!(devices, mac), do: Enum.find(devices, &(&1.mac == mac))

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

  defp apply_filters(devices, [_unknown | rest]), do: apply_filters(devices, rest)

  defp managed_path(opts, config) do
    Keyword.get(opts, :managed_devices_path) ||
      Keyword.get(opts, :managed_path) ||
      config_value(config, :managed_devices_path, "managed_devices_path") ||
      Path.join(YellowDog.Config.get_data_dir(), "netboot/managed_devices.json")
  end

  defp legacy_path(opts, config) do
    Keyword.get(opts, :legacy_devices_path) ||
      Keyword.get(opts, :legacy_path) ||
      config_value(config, :persist_path, "persist_path") ||
      @default_legacy_path
  end

  defp config_value(config, atom_key, string_key) when is_map(config) do
    Map.get(config, atom_key, Map.get(config, string_key))
  end

  defp config_value(_config, _atom_key, _string_key), do: nil
end
