defmodule YellowDog.Netboot.Device.Persistence do
  @moduledoc """
  Lossless managed JSON persistence and legacy TOML loading for devices.
  """

  alias YellowDog.Netboot.Device
  alias YellowDog.Netboot.ManagedStorage.AtomicJson

  @version 2
  @legacy_version 1
  @default_max_bytes 1_048_576
  @empty_snapshot %{"version" => @version, "devices" => [], "tombstones" => []}

  @type tombstone :: %{uuid: String.t() | nil, mac: String.t()}
  @type state_snapshot :: %{devices: [Device.t()], tombstones: [tombstone()]}

  @doc "Atomically save a complete managed device snapshot."
  @spec save(String.t(), [Device.t()], keyword()) :: :ok | {:error, term()}
  def save(path, devices, opts \\ []) do
    save_state(path, %{devices: devices, tombstones: []}, opts)
  end

  @doc "Atomically save devices and legacy-suppression tombstones."
  @spec save_state(String.t(), state_snapshot(), keyword()) :: :ok | {:error, term()}
  def save_state(path, snapshot, opts \\ []) do
    with :ok <- validate_state(snapshot) do
      snapshot = stable_state(snapshot)

      envelope = %{
        "version" => @version,
        "devices" => Enum.map(snapshot.devices, &encode_device/1),
        "tombstones" => Enum.map(snapshot.tombstones, &encode_tombstone/1)
      }

      with :ok <- validate_envelope_size(envelope, opts) do
        AtomicJson.write(path, envelope, opts)
      end
    end
  end

  @doc "Load a complete managed device snapshot."
  @spec load(String.t(), keyword()) :: {:ok, [Device.t()]} | {:error, term()}
  def load(path, opts \\ []) do
    with {:ok, %{devices: devices}} <- load_state(path, opts) do
      {:ok, devices}
    end
  end

  @doc "Load devices and legacy-suppression tombstones."
  @spec load_state(String.t(), keyword()) :: {:ok, state_snapshot()} | {:error, term()}
  def load_state(path, opts \\ []) do
    with {:ok, envelope} <- AtomicJson.read(path, @empty_snapshot, opts),
         {:ok, snapshot} <- decode_envelope(envelope),
         :ok <- validate_state(snapshot) do
      {:ok, stable_state(snapshot)}
    end
  end

  @doc false
  @spec validate_state(term()) :: :ok | {:error, :invalid_snapshot}
  def validate_state(%{devices: devices, tombstones: tombstones} = snapshot)
      when map_size(snapshot) == 2 do
    with :ok <- validate_snapshot(devices),
         :ok <- validate_tombstones(tombstones) do
      :ok
    end
  end

  def validate_state(_snapshot), do: {:error, :invalid_snapshot}

  @doc "Load devices written by the prior TOML persistence format."
  @spec load_legacy(String.t()) :: {:ok, [Device.t()]} | {:error, term()}
  def load_legacy(path) do
    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, data} -> {:ok, deserialize_legacy_devices(data)}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_envelope(
         %{"version" => @version, "devices" => devices, "tombstones" => tombstones} = envelope
       )
       when map_size(envelope) == 3 and is_list(devices) and is_list(tombstones) do
    with {:ok, devices} <- decode_devices(devices, @version),
         {:ok, tombstones} <- decode_tombstones(tombstones) do
      {:ok, %{devices: devices, tombstones: tombstones}}
    end
  end

  defp decode_envelope(%{"version" => @legacy_version, "devices" => devices} = envelope)
       when map_size(envelope) == 2 and is_list(devices) do
    with {:ok, devices} <- decode_devices(devices, @legacy_version) do
      {:ok, %{devices: devices, tombstones: []}}
    end
  end

  defp decode_envelope(%{"version" => version}) when version != @version,
    do: {:error, :unsupported_version}

  defp decode_envelope(_envelope), do: {:error, :invalid_snapshot}

  defp decode_devices(devices, version) do
    Enum.reduce_while(devices, {:ok, []}, fn encoded, {:ok, decoded} ->
      case decode_device(encoded, version) do
        {:ok, device} -> {:cont, {:ok, [device | decoded]}}
        {:error, :invalid_snapshot} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp encode_device(device) do
    %{
      "mac" => device.mac,
      "uuid" => device.uuid,
      "hostname" => device.hostname,
      "arch" => encode_atom(device.arch),
      "profile_id" => device.profile_id,
      "ip_address" => encode_ip_address(device.ip_address),
      "last_error" => device.last_error,
      "state" => Atom.to_string(device.state),
      "hardware_info" => device.hardware_info,
      "first_seen" => encode_datetime(device.first_seen),
      "last_seen" => encode_datetime(device.last_seen),
      "install_attempts" => device.install_attempts,
      "tags" => device.tags,
      "state_history" => Enum.map(device.state_history, &encode_history_entry/1),
      "slot" => %{
        "active" => Atom.to_string(device.slot.active),
        "pending" => encode_atom(device.slot.pending)
      },
      "rescue_mode" => device.rescue_mode
    }
  end

  defp decode_device(
         %{
           "mac" => mac,
           "uuid" => uuid,
           "hostname" => hostname,
           "arch" => arch,
           "profile_id" => profile_id,
           "ip_address" => ip_address,
           "last_error" => last_error,
           "state" => state,
           "hardware_info" => hardware_info,
           "first_seen" => first_seen,
           "last_seen" => last_seen,
           "install_attempts" => install_attempts,
           "tags" => tags,
           "state_history" => state_history,
           "slot" => slot,
           "rescue_mode" => rescue_mode
         },
         version
       ) do
    with {:ok, arch} <- decode_optional_atom(arch, Device.valid_arches()),
         {:ok, state} <- decode_atom(state, Device.valid_states()),
         {:ok, ip_address} <- decode_ip_address(ip_address),
         {:ok, hardware_info} <- decode_hardware_info(hardware_info, version),
         true <- is_map(hardware_info),
         {:ok, first_seen} <- decode_datetime(first_seen),
         {:ok, last_seen} <- decode_datetime(last_seen),
         {:ok, state_history} <- decode_history(state_history),
         {:ok, slot} <- decode_slot(slot) do
      device = %Device{
        mac: mac,
        uuid: uuid,
        hostname: hostname,
        arch: arch,
        profile_id: profile_id,
        ip_address: ip_address,
        last_error: last_error,
        state: state,
        hardware_info: hardware_info,
        first_seen: first_seen,
        last_seen: last_seen,
        install_attempts: install_attempts,
        tags: tags,
        state_history: state_history,
        slot: slot,
        rescue_mode: rescue_mode
      }

      case Device.validate(device) do
        :ok -> {:ok, device}
        {:error, :invalid_device} -> {:error, :invalid_snapshot}
      end
    else
      _other -> {:error, :invalid_snapshot}
    end
  end

  defp decode_device(_encoded, _version), do: {:error, :invalid_snapshot}

  defp encode_history_entry(%{state: state, at: at}) do
    %{"state" => Atom.to_string(state), "at" => DateTime.to_iso8601(at)}
  end

  defp decode_history(history) when is_list(history) do
    Enum.reduce_while(history, {:ok, []}, fn
      %{"state" => state, "at" => at}, {:ok, entries} ->
        with {:ok, state} <- decode_atom(state, Device.valid_states()),
             {:ok, at} <- decode_required_datetime(at) do
          {:cont, {:ok, [%{state: state, at: at} | entries]}}
        else
          _other -> {:halt, {:error, :invalid_snapshot}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_snapshot}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp decode_history(_history), do: {:error, :invalid_snapshot}

  defp encode_ip_address(nil), do: nil

  defp encode_ip_address(address) when tuple_size(address) == 4 do
    %{"family" => "ipv4", "address" => Tuple.to_list(address)}
  end

  defp encode_ip_address(address) when tuple_size(address) == 8 do
    %{"family" => "ipv6", "address" => Tuple.to_list(address)}
  end

  defp decode_ip_address(nil), do: {:ok, nil}

  defp decode_ip_address(%{"family" => "ipv4", "address" => address})
       when is_list(address) and length(address) == 4 do
    decode_ip_parts(address, 255)
  end

  defp decode_ip_address(%{"family" => "ipv6", "address" => address})
       when is_list(address) and length(address) == 8 do
    decode_ip_parts(address, 65_535)
  end

  defp decode_ip_address(_address), do: {:error, :invalid_snapshot}

  defp decode_ip_parts(parts, maximum) do
    if Enum.all?(parts, &(is_integer(&1) and &1 in 0..maximum)) do
      {:ok, List.to_tuple(parts)}
    else
      {:error, :invalid_snapshot}
    end
  end

  defp decode_slot(%{"active" => active, "pending" => pending}) do
    with {:ok, active} <- decode_atom(active, [:a, :b]),
         {:ok, pending} <- decode_optional_atom(pending, [:a, :b]) do
      {:ok, %{active: active, pending: pending}}
    end
  end

  defp decode_slot(_slot), do: {:error, :invalid_snapshot}

  defp encode_datetime(nil), do: nil
  defp encode_datetime(datetime), do: DateTime.to_iso8601(datetime)

  defp decode_datetime(nil), do: {:ok, nil}
  defp decode_datetime(value), do: decode_required_datetime(value)

  defp decode_required_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _other -> {:error, :invalid_snapshot}
    end
  end

  defp decode_required_datetime(_value), do: {:error, :invalid_snapshot}

  defp encode_atom(nil), do: nil
  defp encode_atom(value), do: Atom.to_string(value)

  defp decode_optional_atom(nil, _valid), do: {:ok, nil}
  defp decode_optional_atom(value, valid), do: decode_atom(value, valid)

  defp decode_atom(value, valid) when is_binary(value) do
    case Enum.find(valid, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_snapshot}
      atom -> {:ok, atom}
    end
  end

  defp decode_atom(_value, _valid), do: {:error, :invalid_snapshot}

  defp decode_hardware_info(value, @version) when is_map(value), do: {:ok, value}
  defp decode_hardware_info(value, @legacy_version), do: decode_legacy_term(value)
  defp decode_hardware_info(_value, _version), do: {:error, :invalid_snapshot}

  defp decode_legacy_term(value)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
       do: {:ok, value}

  defp decode_legacy_term(%{"$type" => "map", "entries" => entries}) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      [encoded_key, encoded_value], {:ok, map} ->
        with true <- is_binary(encoded_key),
             {:ok, value} <- decode_legacy_term(encoded_value),
             false <- Map.has_key?(map, encoded_key) do
          {:cont, {:ok, Map.put(map, encoded_key, value)}}
        else
          _other -> {:halt, {:error, :invalid_snapshot}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_snapshot}}
    end)
  end

  defp decode_legacy_term(values) when is_list(values), do: decode_legacy_terms(values)
  defp decode_legacy_term(_value), do: {:error, :invalid_snapshot}

  defp decode_legacy_terms(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
      case decode_legacy_term(value) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, :invalid_snapshot} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp encode_tombstone(%{uuid: uuid, mac: mac}) do
    %{"uuid" => uuid, "mac" => mac}
  end

  defp decode_tombstones(tombstones) do
    Enum.reduce_while(tombstones, {:ok, []}, fn encoded, {:ok, decoded} ->
      case decode_tombstone(encoded) do
        {:ok, tombstone} -> {:cont, {:ok, [tombstone | decoded]}}
        {:error, :invalid_snapshot} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_tombstone(%{"uuid" => uuid, "mac" => mac} = tombstone)
       when map_size(tombstone) == 2 do
    decoded = %{uuid: uuid, mac: mac}

    if valid_tombstone?(decoded) do
      {:ok, decoded}
    else
      {:error, :invalid_snapshot}
    end
  end

  defp decode_tombstone(_tombstone), do: {:error, :invalid_snapshot}

  defp validate_snapshot(devices) when is_list(devices) do
    Enum.reduce_while(devices, {:ok, MapSet.new(), MapSet.new()}, fn device, {:ok, macs, uuids} ->
      with :ok <- Device.validate(device),
           false <- MapSet.member?(macs, device.mac),
           false <- duplicate_uuid?(uuids, device.uuid) do
        uuids = if is_nil(device.uuid), do: uuids, else: MapSet.put(uuids, device.uuid)
        {:cont, {:ok, MapSet.put(macs, device.mac), uuids}}
      else
        _other -> {:halt, {:error, :invalid_snapshot}}
      end
    end)
    |> case do
      {:ok, _macs, _uuids} -> :ok
      error -> error
    end
  end

  defp validate_snapshot(_devices), do: {:error, :invalid_snapshot}

  defp duplicate_uuid?(_uuids, nil), do: false
  defp duplicate_uuid?(uuids, uuid), do: MapSet.member?(uuids, uuid)

  defp validate_tombstones(tombstones) when is_list(tombstones) do
    Enum.reduce_while(tombstones, {:ok, MapSet.new()}, fn tombstone, {:ok, identities} ->
      identity = tombstone_identity(tombstone)

      if valid_tombstone?(tombstone) and not MapSet.member?(identities, identity) do
        {:cont, {:ok, MapSet.put(identities, identity)}}
      else
        {:halt, {:error, :invalid_snapshot}}
      end
    end)
    |> case do
      {:ok, _identities} -> :ok
      error -> error
    end
  end

  defp validate_tombstones(_tombstones), do: {:error, :invalid_snapshot}

  defp valid_tombstone?(%{uuid: uuid, mac: mac} = tombstone) when map_size(tombstone) == 2 do
    (is_nil(uuid) or (is_binary(uuid) and uuid != "" and String.valid?(uuid))) and
      Device.valid_mac?(mac)
  end

  defp valid_tombstone?(_tombstone), do: false

  defp tombstone_identity(%{uuid: uuid, mac: mac}), do: {uuid, mac}
  defp tombstone_identity(_tombstone), do: :invalid

  defp stable_snapshot(devices), do: Enum.sort_by(devices, & &1.mac)

  defp stable_state(%{devices: devices, tombstones: tombstones}) do
    %{
      devices: stable_snapshot(devices),
      tombstones: Enum.sort_by(tombstones, &{&1.mac, &1.uuid || ""})
    }
  end

  defp validate_envelope_size(envelope, opts) when is_list(opts) do
    case Keyword.get(opts, :max_bytes, @default_max_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 ->
        validate_encoded_size(envelope, max_bytes)

      _invalid ->
        {:error, :invalid_options}
    end
  end

  defp validate_envelope_size(_envelope, _opts), do: {:error, :invalid_options}

  defp validate_encoded_size(envelope, max_bytes) do
    case Jason.encode(envelope) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes -> :ok
      {:ok, _encoded} -> {:error, :too_large}
      {:error, _reason} -> {:error, :invalid_snapshot}
    end
  rescue
    _error -> {:error, :invalid_snapshot}
  end

  defp deserialize_legacy_devices(%{"devices" => devices}) when is_map(devices) do
    Enum.map(devices, fn {_key, attrs} ->
      now = DateTime.utc_now()

      %Device{
        mac: attrs |> Map.get("mac", "") |> Device.normalize_mac(),
        uuid: Map.get(attrs, "uuid"),
        hostname: Map.get(attrs, "hostname"),
        arch: parse_legacy_atom(Map.get(attrs, "arch"), Device.valid_arches()),
        profile_id: Map.get(attrs, "profile_id"),
        state:
          parse_legacy_atom(
            Map.get(attrs, "state", "discovered"),
            Device.valid_states(),
            :discovered
          ),
        install_attempts: Map.get(attrs, "install_attempts", 0),
        last_error: Map.get(attrs, "last_error"),
        tags: Map.get(attrs, "tags", []),
        first_seen: now,
        last_seen: now
      }
    end)
  end

  defp deserialize_legacy_devices(_data), do: []

  defp parse_legacy_atom(nil, _valid), do: nil

  defp parse_legacy_atom(value, valid, fallback \\ nil) when is_binary(value) do
    Enum.find(valid, fallback, &(Atom.to_string(&1) == value))
  end
end
