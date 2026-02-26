defmodule YellowDog.Fingerprint.Database do
  @moduledoc """
  Store.Ets-backed fingerprint database with TOML persistence.

  Manages four Store.Ets collections:
  - `:fp_profiles` — device profiles (id → DeviceProfile)
  - `:fp_fingerprints_v4` — DHCPv4 fingerprint→profile mappings
  - `:fp_fingerprints_v6` — DHCPv6 fingerprint→profile mappings
  - `:fp_overrides` — user overrides (fingerprint_hash → profile_id)

  Data is loaded from TOML files at startup and persisted on changes.
  """

  use GenServer

  require Logger

  alias YellowDog.Data.{Collection, Store}
  alias YellowDog.Fingerprint.Types.{DeviceProfile, Fingerprint}

  @profiles_collection %Collection{name: :fp_profiles, key_field: :id, adapter: Store.Ets}
  @fingerprints_v4_collection %Collection{name: :fp_fingerprints_v4, key_field: :hash, adapter: Store.Ets}
  @fingerprints_v6_collection %Collection{name: :fp_fingerprints_v6, key_field: :hash, adapter: Store.Ets}
  @overrides_collection %Collection{name: :fp_overrides, key_field: :hash, adapter: Store.Ets}

  # --- Public API ---

  def start_link(opts) do
    data_dir = Keyword.get(opts, :data_dir, "data/fingerprint")
    GenServer.start_link(__MODULE__, data_dir, name: __MODULE__)
  end

  @doc "Returns a profile by ID."
  @spec get_profile(String.t()) :: {:ok, DeviceProfile.t()} | :not_found
  def get_profile(profile_id) do
    case Store.get(store(:profiles), profile_id) do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> :not_found
    end
  end

  @doc "Lists all device profiles."
  @spec list_profiles() :: [DeviceProfile.t()]
  def list_profiles do
    {:ok, profiles} = Store.list(store(:profiles))
    profiles
  end

  @doc "Looks up a v4 fingerprint mapping by hash."
  @spec lookup_v4(binary()) :: {:ok, %{profile_id: String.t(), confidence: non_neg_integer()}} | :not_found
  def lookup_v4(hash) do
    case Store.get(store(:v4), hash) do
      {:ok, mapping} -> {:ok, mapping}
      {:error, :not_found} -> :not_found
    end
  end

  @doc "Looks up a v6 fingerprint mapping by hash."
  @spec lookup_v6(binary()) :: {:ok, %{profile_id: String.t(), confidence: non_neg_integer()}} | :not_found
  def lookup_v6(hash) do
    case Store.get(store(:v6), hash) do
      {:ok, mapping} -> {:ok, mapping}
      {:error, :not_found} -> :not_found
    end
  end

  @doc "Looks up a user override by fingerprint hash."
  @spec lookup_override(binary()) :: {:ok, %{profile_id: String.t(), note: String.t() | nil}} | :not_found
  def lookup_override(hash) do
    case Store.get(store(:overrides), hash) do
      {:ok, override} -> {:ok, override}
      {:error, :not_found} -> :not_found
    end
  end

  @doc "Adds a user override mapping fingerprint hash to profile."
  @spec add_override(binary(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def add_override(fingerprint_hash, profile_id, note \\ nil) do
    GenServer.call(__MODULE__, {:add_override, fingerprint_hash, profile_id, note})
  end

  @doc "Lists all known fingerprints (v4 + v6 combined)."
  @spec list_fingerprints() :: [Fingerprint.t()]
  def list_fingerprints do
    {:ok, v4} = Store.list(store(:v4))
    {:ok, v6} = Store.list(store(:v6))
    v4 ++ v6
  end

  @doc "Lists unknown (unmatched) fingerprints — those without profile mappings."
  @spec list_unknown_fingerprints() :: [Fingerprint.t()]
  def list_unknown_fingerprints do
    list_fingerprints()
    |> Enum.filter(fn
      %{profile_id: nil} -> true
      _ -> false
    end)
    |> Enum.sort_by(& &1.hit_count, :desc)
  end

  @doc "Records or updates a fingerprint observation."
  @spec record_fingerprint(Fingerprint.t()) :: :ok
  def record_fingerprint(%Fingerprint{} = fp) do
    GenServer.cast(__MODULE__, {:record_fingerprint, fp})
  end

  @doc "Returns all v4 fingerprint entries for fuzzy matching."
  @spec all_v4_entries() :: [map()]
  def all_v4_entries do
    {:ok, entries} = Store.list(store(:v4))
    entries
  end

  @doc "Returns all v6 fingerprint entries for fuzzy matching."
  @spec all_v6_entries() :: [map()]
  def all_v6_entries do
    {:ok, entries} = Store.list(store(:v6))
    entries
  end

  @doc "Returns database statistics."
  @spec stats() :: map()
  def stats do
    {:ok, profiles_count} = Store.count(store(:profiles))
    {:ok, v4_count} = Store.count(store(:v4))
    {:ok, v6_count} = Store.count(store(:v6))
    {:ok, overrides_count} = Store.count(store(:overrides))

    %{
      profiles: profiles_count,
      fingerprints_v4: v4_count,
      fingerprints_v6: v6_count,
      overrides: overrides_count
    }
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(data_dir) do
    {:ok, profiles_store} = Store.init(@profiles_collection, [])
    {:ok, v4_store} = Store.init(@fingerprints_v4_collection, [])
    {:ok, v6_store} = Store.init(@fingerprints_v6_collection, [])
    {:ok, overrides_store} = Store.init(@overrides_collection, [])

    stores = %{profiles: profiles_store, v4: v4_store, v6: v6_store, overrides: overrides_store}
    :persistent_term.put({__MODULE__, :stores}, stores)

    load_profiles(stores, data_dir)
    load_fingerprints(stores, data_dir, :dhcpv4)
    load_fingerprints(stores, data_dir, :dhcpv6)
    load_overrides(stores, data_dir)

    {:ok, %{stores: stores, data_dir: data_dir}}
  end

  @impl true
  def handle_call({:add_override, hash, profile_id, note}, _from, state) do
    override = %{profile_id: profile_id, note: note, created_at: DateTime.utc_now()}
    {:ok, overrides_store} = Store.put(state.stores.overrides, hash, override)
    stores = %{state.stores | overrides: overrides_store}
    :persistent_term.put({__MODULE__, :stores}, stores)
    save_overrides(stores, state.data_dir)
    {:reply, :ok, %{state | stores: stores}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_fingerprint, %Fingerprint{protocol: :dhcpv4} = fp}, state) do
    stores = update_fingerprint_entry(state.stores, :v4, fp)
    {:noreply, %{state | stores: stores}}
  end

  def handle_cast({:record_fingerprint, %Fingerprint{protocol: :dhcpv6} = fp}, state) do
    stores = update_fingerprint_entry(state.stores, :v6, fp)
    {:noreply, %{state | stores: stores}}
  end

  # --- Private ---

  defp store(key) do
    stores = :persistent_term.get({__MODULE__, :stores})
    Map.fetch!(stores, key)
  end

  defp update_fingerprint_entry(stores, table_key, %Fingerprint{id: id} = fp) do
    store_state = Map.fetch!(stores, table_key)

    case Store.get(store_state, id) do
      {:ok, existing} ->
        updated = %{existing | last_seen: fp.last_seen, hit_count: existing.hit_count + 1}
        {:ok, new_store} = Store.put(store_state, id, updated)
        updated_stores = Map.put(stores, table_key, new_store)
        :persistent_term.put({__MODULE__, :stores}, updated_stores)
        updated_stores

      {:error, :not_found} ->
        entry = %{
          parameter_list: fp.parameter_list,
          vendor_class: fp.vendor_class,
          hostname_pattern: fp.hostname_pattern,
          profile_id: nil,
          confidence: 0,
          hit_count: 1,
          first_seen: fp.first_seen,
          last_seen: fp.last_seen
        }

        {:ok, new_store} = Store.put(store_state, id, entry)
        updated_stores = Map.put(stores, table_key, new_store)
        :persistent_term.put({__MODULE__, :stores}, updated_stores)
        updated_stores
    end
  end

  defp load_profiles(stores, data_dir) do
    path = Path.join(data_dir, "profiles.toml")

    case read_toml(path) do
      {:ok, %{"profiles" => profiles}} ->
        Enum.each(profiles, fn p ->
          profile = %DeviceProfile{
            id: p["id"],
            name: p["name"],
            os_family: p["os_family"],
            os_version: p["os_version"],
            device_type: DeviceProfile.parse_device_type(p["device_type"] || "unknown"),
            vendor: p["vendor"],
            confidence: p["confidence"] || 0,
            source: :local
          }

          Store.put(stores.profiles, profile.id, profile)
        end)

      _ ->
        :ok
    end
  end

  defp load_fingerprints(stores, data_dir, :dhcpv4) do
    path = Path.join(data_dir, "fingerprints_v4.toml")
    load_fingerprint_file(stores.v4, path, :dhcpv4)
  end

  defp load_fingerprints(stores, data_dir, :dhcpv6) do
    path = Path.join(data_dir, "fingerprints_v6.toml")
    load_fingerprint_file(stores.v6, path, :dhcpv6)
  end

  defp load_fingerprint_file(store_state, path, protocol) do
    case read_toml(path) do
      {:ok, %{"fingerprints" => fingerprints}} ->
        Enum.each(fingerprints, fn f ->
          param_list = f["parameter_list"] || []
          vendor_class = f["vendor_class_pattern"]
          hash = Fingerprint.compute_id(protocol, param_list, vendor_class)

          entry = %{
            parameter_list: param_list,
            vendor_class: vendor_class,
            profile_id: f["profile_id"],
            confidence: f["confidence"] || 0,
            hostname_pattern: nil,
            hit_count: 0,
            first_seen: nil,
            last_seen: nil
          }

          Store.put(store_state, hash, entry)
        end)

      _ ->
        :ok
    end
  end

  defp load_overrides(stores, data_dir) do
    path = Path.join(data_dir, "overrides.toml")

    case read_toml(path) do
      {:ok, data} ->
        # Load custom profiles
        for p <- Map.get(data, "custom_profiles", []) do
          profile = %DeviceProfile{
            id: p["id"],
            name: p["name"],
            os_family: p["os_family"],
            os_version: p["os_version"],
            device_type: DeviceProfile.parse_device_type(p["device_type"] || "unknown"),
            vendor: p["vendor"],
            confidence: 100,
            source: :user_override
          }

          Store.put(stores.profiles, profile.id, profile)
        end

        # Load overrides
        for o <- Map.get(data, "overrides", []) do
          override = %{
            profile_id: o["profile_id"],
            note: o["note"],
            created_at: parse_datetime(o["created_at"])
          }

          Store.put(stores.overrides, o["fingerprint_hash"], override)
        end

      _ ->
        :ok
    end
  end

  defp save_overrides(stores, data_dir) do
    path = Path.join(data_dir, "overrides.toml")

    case File.mkdir_p(data_dir) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[Fingerprint] Failed to create data dir: #{inspect(reason)}")
    end

    # We need the keys too — get from ETS directly since Store.list only returns values
    overrides =
      :ets.tab2list(stores.overrides.table)
      |> Enum.map(fn {hash, o} ->
        "[[overrides]]\nfingerprint_hash = #{inspect(hash)}\nprofile_id = #{inspect(o.profile_id)}\nnote = #{inspect(o.note || "")}\ncreated_at = #{DateTime.to_iso8601(o.created_at)}"
      end)
      |> Enum.join("\n\n")

    {:ok, profiles} = Store.list(stores.profiles)

    custom_profiles =
      profiles
      |> Enum.filter(&(&1.source == :user_override))
      |> Enum.map(fn p ->
        "[[custom_profiles]]\nid = #{inspect(p.id)}\nname = #{inspect(p.name)}\ndevice_type = #{inspect(to_string(p.device_type))}\nvendor = #{inspect(p.vendor || "")}"
      end)
      |> Enum.join("\n\n")

    content =
      [custom_profiles, overrides]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[Fingerprint] Failed to save overrides: #{inspect(reason)}")
    end
  end

  defp read_toml(path) do
    if File.exists?(path) do
      case Toml.decode_file(path) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp parse_datetime(_), do: DateTime.utc_now()
end
