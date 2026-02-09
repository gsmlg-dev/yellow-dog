defmodule YellowDog.Fingerprint.Database do
  @moduledoc """
  ETS-backed fingerprint database with TOML persistence.

  Manages four ETS tables:
  - `:fp_profiles` — device profiles (id → DeviceProfile)
  - `:fp_fingerprints_v4` — DHCPv4 fingerprint→profile mappings
  - `:fp_fingerprints_v6` — DHCPv6 fingerprint→profile mappings
  - `:fp_overrides` — user overrides (fingerprint_hash → profile_id)

  Data is loaded from TOML files at startup and persisted on changes.
  """

  use GenServer

  alias YellowDog.Fingerprint.Types.{DeviceProfile, Fingerprint}

  @profiles_table :fp_profiles
  @fingerprints_v4_table :fp_fingerprints_v4
  @fingerprints_v6_table :fp_fingerprints_v6
  @overrides_table :fp_overrides

  # --- Public API ---

  def start_link(opts) do
    data_dir = Keyword.get(opts, :data_dir, "data/fingerprint")
    GenServer.start_link(__MODULE__, data_dir, name: __MODULE__)
  end

  @doc "Returns a profile by ID."
  @spec get_profile(String.t()) :: {:ok, DeviceProfile.t()} | :not_found
  def get_profile(profile_id) do
    case :ets.lookup(@profiles_table, profile_id) do
      [{^profile_id, profile}] -> {:ok, profile}
      [] -> :not_found
    end
  end

  @doc "Lists all device profiles."
  @spec list_profiles() :: [DeviceProfile.t()]
  def list_profiles do
    :ets.tab2list(@profiles_table)
    |> Enum.map(fn {_id, profile} -> profile end)
  end

  @doc "Looks up a v4 fingerprint mapping by hash."
  @spec lookup_v4(binary()) :: {:ok, %{profile_id: String.t(), confidence: non_neg_integer()}} | :not_found
  def lookup_v4(hash) do
    case :ets.lookup(@fingerprints_v4_table, hash) do
      [{^hash, mapping}] -> {:ok, mapping}
      [] -> :not_found
    end
  end

  @doc "Looks up a v6 fingerprint mapping by hash."
  @spec lookup_v6(binary()) :: {:ok, %{profile_id: String.t(), confidence: non_neg_integer()}} | :not_found
  def lookup_v6(hash) do
    case :ets.lookup(@fingerprints_v6_table, hash) do
      [{^hash, mapping}] -> {:ok, mapping}
      [] -> :not_found
    end
  end

  @doc "Looks up a user override by fingerprint hash."
  @spec lookup_override(binary()) :: {:ok, %{profile_id: String.t(), note: String.t() | nil}} | :not_found
  def lookup_override(hash) do
    case :ets.lookup(@overrides_table, hash) do
      [{^hash, override}] -> {:ok, override}
      [] -> :not_found
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
    v4 = :ets.tab2list(@fingerprints_v4_table) |> Enum.map(fn {_h, m} -> m end)
    v6 = :ets.tab2list(@fingerprints_v6_table) |> Enum.map(fn {_h, m} -> m end)
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
    :ets.tab2list(@fingerprints_v4_table)
    |> Enum.map(fn {hash, entry} -> Map.put(entry, :hash, hash) end)
  end

  @doc "Returns all v6 fingerprint entries for fuzzy matching."
  @spec all_v6_entries() :: [map()]
  def all_v6_entries do
    :ets.tab2list(@fingerprints_v6_table)
    |> Enum.map(fn {hash, entry} -> Map.put(entry, :hash, hash) end)
  end

  @doc "Returns database statistics."
  @spec stats() :: map()
  def stats do
    %{
      profiles: :ets.info(@profiles_table, :size),
      fingerprints_v4: :ets.info(@fingerprints_v4_table, :size),
      fingerprints_v6: :ets.info(@fingerprints_v6_table, :size),
      overrides: :ets.info(@overrides_table, :size)
    }
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(data_dir) do
    :ets.new(@profiles_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@fingerprints_v4_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@fingerprints_v6_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@overrides_table, [:named_table, :set, :public, read_concurrency: true])

    load_profiles(data_dir)
    load_fingerprints(data_dir, :dhcpv4)
    load_fingerprints(data_dir, :dhcpv6)
    load_overrides(data_dir)

    {:ok, %{data_dir: data_dir}}
  end

  @impl true
  def handle_call({:add_override, hash, profile_id, note}, _from, state) do
    override = %{profile_id: profile_id, note: note, created_at: DateTime.utc_now()}
    :ets.insert(@overrides_table, {hash, override})
    save_overrides(state.data_dir)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:record_fingerprint, %Fingerprint{protocol: :dhcpv4} = fp}, state) do
    table = @fingerprints_v4_table
    update_fingerprint_entry(table, fp)
    {:noreply, state}
  end

  def handle_cast({:record_fingerprint, %Fingerprint{protocol: :dhcpv6} = fp}, state) do
    table = @fingerprints_v6_table
    update_fingerprint_entry(table, fp)
    {:noreply, state}
  end

  # --- Private ---

  defp update_fingerprint_entry(table, %Fingerprint{id: id} = fp) do
    case :ets.lookup(table, id) do
      [{^id, existing}] ->
        updated = %{existing | last_seen: fp.last_seen, hit_count: existing.hit_count + 1}
        :ets.insert(table, {id, updated})

      [] ->
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

        :ets.insert(table, {id, entry})
    end
  end

  defp load_profiles(data_dir) do
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

          :ets.insert(@profiles_table, {profile.id, profile})
        end)

      _ ->
        :ok
    end
  end

  defp load_fingerprints(data_dir, :dhcpv4) do
    path = Path.join(data_dir, "fingerprints_v4.toml")
    table = @fingerprints_v4_table
    load_fingerprint_file(path, table, :dhcpv4)
  end

  defp load_fingerprints(data_dir, :dhcpv6) do
    path = Path.join(data_dir, "fingerprints_v6.toml")
    table = @fingerprints_v6_table
    load_fingerprint_file(path, table, :dhcpv6)
  end

  defp load_fingerprint_file(path, table, protocol) do
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

          :ets.insert(table, {hash, entry})
        end)

      _ ->
        :ok
    end
  end

  defp load_overrides(data_dir) do
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

          :ets.insert(@profiles_table, {profile.id, profile})
        end

        # Load overrides
        for o <- Map.get(data, "overrides", []) do
          override = %{
            profile_id: o["profile_id"],
            note: o["note"],
            created_at: parse_datetime(o["created_at"])
          }

          :ets.insert(@overrides_table, {o["fingerprint_hash"], override})
        end

      _ ->
        :ok
    end
  end

  defp save_overrides(data_dir) do
    path = Path.join(data_dir, "overrides.toml")
    File.mkdir_p!(data_dir)

    overrides =
      :ets.tab2list(@overrides_table)
      |> Enum.map(fn {hash, o} ->
        "[[overrides]]\nfingerprint_hash = #{inspect(hash)}\nprofile_id = #{inspect(o.profile_id)}\nnote = #{inspect(o.note || "")}\ncreated_at = #{DateTime.to_iso8601(o.created_at)}"
      end)
      |> Enum.join("\n\n")

    custom_profiles =
      list_profiles()
      |> Enum.filter(&(&1.source == :user_override))
      |> Enum.map(fn p ->
        "[[custom_profiles]]\nid = #{inspect(p.id)}\nname = #{inspect(p.name)}\ndevice_type = #{inspect(to_string(p.device_type))}\nvendor = #{inspect(p.vendor || "")}"
      end)
      |> Enum.join("\n\n")

    content =
      [custom_profiles, overrides]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    File.write!(path, content)
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
