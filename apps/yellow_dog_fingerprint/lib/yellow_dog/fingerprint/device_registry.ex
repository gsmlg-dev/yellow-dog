defmodule YellowDog.Fingerprint.DeviceRegistry do
  @moduledoc """
  Device state management with ETS storage and periodic TOML persistence.

  Tracks observed devices keyed by MAC address. Correlates DHCPv4 and
  DHCPv6 observations into a unified device record. Periodically flushes
  state to `data/fingerprint/devices.toml`.
  """

  use GenServer

  alias YellowDog.Fingerprint.Types.Device

  require Logger

  @table :fp_devices
  @default_flush_interval 60_000

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a device by MAC address."
  @spec get(String.t()) :: {:ok, Device.t()} | :not_found
  def get(mac) do
    case :ets.lookup(@table, normalize_mac(mac)) do
      [{_mac, device}] -> {:ok, device}
      [] -> :not_found
    end
  end

  @doc "Lists all observed devices."
  @spec list() :: [Device.t()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_mac, device} -> device end)
    |> Enum.sort_by(& &1.last_seen, {:desc, DateTime})
  end

  @doc "Returns device registry statistics."
  @spec stats() :: map()
  def stats do
    devices = list()
    total = length(devices)
    identified = Enum.count(devices, & &1.profile_id)

    %{
      total_devices: total,
      identified_devices: identified,
      unknown_devices: total - identified,
      avg_confidence:
        if(identified > 0,
          do: round(Enum.sum(Enum.map(devices, & &1.profile_confidence)) / total),
          else: 0
        )
    }
  end

  @doc """
  Updates or creates a device entry.

  Expects a map with:
  - `:fingerprint` — Fingerprint struct
  - `:profile_id` — matched profile ID (or nil)
  - `:profile_confidence` — match confidence (0-100)
  - `:oui_vendor` — OUI vendor string (or nil)
  - `:hostname` — hostname (or nil)
  - `:source_ip` — IP address tuple (or nil)
  - `:duid` — DHCPv6 DUID (or nil)
  """
  @spec update_device(String.t(), map()) :: :ok
  def update_device(mac, attrs) do
    GenServer.cast(__MODULE__, {:update_device, normalize_mac(mac), attrs})
  end

  @doc "Triggers an immediate flush to disk."
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, "data/fingerprint")
    flush_interval = Application.get_env(:yellow_dog_fingerprint, :device_flush_interval_ms, @default_flush_interval)

    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    load_devices(data_dir)
    schedule_flush(flush_interval)

    {:ok, %{data_dir: data_dir, flush_interval: flush_interval}}
  end

  @impl true
  def handle_cast({:update_device, mac, attrs}, state) do
    now = DateTime.utc_now()
    fingerprint = attrs[:fingerprint]

    case :ets.lookup(@table, mac) do
      [{^mac, existing}] ->
        updated = merge_device(existing, attrs, fingerprint, now)
        :ets.insert(@table, {mac, updated})
        maybe_broadcast_update(updated)

      [] ->
        device = new_device(mac, attrs, fingerprint, now)
        :ets.insert(@table, {mac, device})
        maybe_broadcast_update(device)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    save_devices(state.data_dir)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    save_devices(state.data_dir)
    schedule_flush(state.flush_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    save_devices(state.data_dir)
    :ok
  end

  # --- Private ---

  defp new_device(mac, attrs, fingerprint, now) do
    {v4_id, v6_id} = fingerprint_ids(fingerprint)
    {v4_addrs, v6_addrs} = ip_lists(attrs[:source_ip])

    %Device{
      id: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
      mac: mac,
      oui_vendor: attrs[:oui_vendor],
      duid: attrs[:duid],
      hostname: attrs[:hostname],
      fingerprint_v4_id: v4_id,
      fingerprint_v6_id: v6_id,
      profile_id: attrs[:profile_id],
      profile_confidence: attrs[:profile_confidence] || 0,
      ipv4_addresses: v4_addrs,
      ipv6_addresses: v6_addrs,
      first_seen: now,
      last_seen: now,
      observation_count: 1,
      metadata: %{}
    }
  end

  defp merge_device(existing, attrs, fingerprint, now) do
    {v4_id, v6_id} = fingerprint_ids(fingerprint)
    {new_v4, new_v6} = ip_lists(attrs[:source_ip])

    # Detect profile change
    old_profile = existing.profile_id
    new_profile = attrs[:profile_id]

    if old_profile != nil and new_profile != nil and old_profile != new_profile do
      :telemetry.execute(
        [:yellow_dog, :fingerprint, :device, :changed],
        %{count: 1},
        %{mac: existing.mac, old_profile: old_profile, new_profile: new_profile}
      )
    end

    %{
      existing
      | oui_vendor: attrs[:oui_vendor] || existing.oui_vendor,
        duid: attrs[:duid] || existing.duid,
        hostname: attrs[:hostname] || existing.hostname,
        fingerprint_v4_id: v4_id || existing.fingerprint_v4_id,
        fingerprint_v6_id: v6_id || existing.fingerprint_v6_id,
        profile_id: new_profile || existing.profile_id,
        profile_confidence: max(attrs[:profile_confidence] || 0, existing.profile_confidence),
        ipv4_addresses: merge_ips(existing.ipv4_addresses, new_v4),
        ipv6_addresses: merge_ips(existing.ipv6_addresses, new_v6),
        last_seen: now,
        observation_count: existing.observation_count + 1
    }
  end

  defp fingerprint_ids(nil), do: {nil, nil}
  defp fingerprint_ids(%{protocol: :dhcpv4, id: id}), do: {id, nil}
  defp fingerprint_ids(%{protocol: :dhcpv6, id: id}), do: {nil, id}

  defp ip_lists(nil), do: {[], []}

  defp ip_lists({_, _, _, _} = ip) do
    {[ip |> :inet.ntoa() |> to_string()], []}
  end

  defp ip_lists({_, _, _, _, _, _, _, _} = ip) do
    {[], [ip |> :inet.ntoa() |> to_string()]}
  end

  defp ip_lists(_), do: {[], []}

  defp merge_ips(existing, new_ips) do
    (existing ++ new_ips)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  defp maybe_broadcast_update(device) do
    Phoenix.PubSub.broadcast(
      YellowDog.PubSub,
      "fingerprint:devices",
      {:device_updated, device}
    )
  rescue
    # PubSub may not be available in test/standalone mode
    _ -> :ok
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end

  defp load_devices(data_dir) do
    path = Path.join(data_dir, "devices.toml")

    case read_toml(path) do
      {:ok, %{"devices" => devices}} ->
        Enum.each(devices, fn d ->
          mac = d["mac"]

          device = %Device{
            id: d["id"] || (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)),
            mac: mac,
            oui_vendor: d["oui_vendor"],
            hostname: d["hostname"],
            fingerprint_v4_id: d["fingerprint_v4_id"],
            fingerprint_v6_id: d["fingerprint_v6_id"],
            profile_id: d["profile_id"],
            profile_confidence: d["profile_confidence"] || 0,
            ipv4_addresses: d["ipv4_addresses"] || [],
            ipv6_addresses: d["ipv6_addresses"] || [],
            first_seen: parse_datetime(d["first_seen"]),
            last_seen: parse_datetime(d["last_seen"]),
            observation_count: d["observation_count"] || 0,
            metadata: d["metadata"] || %{}
          }

          :ets.insert(@table, {mac, device})
        end)

      _ ->
        :ok
    end
  end

  defp save_devices(data_dir) do
    path = Path.join(data_dir, "devices.toml")
    File.mkdir_p!(data_dir)

    devices = list()

    content =
      devices
      |> Enum.map(fn d ->
        v4 = Enum.map_join(d.ipv4_addresses, ", ", &inspect/1)
        v6 = Enum.map_join(d.ipv6_addresses, ", ", &inspect/1)

        """
        [[devices]]
        id = #{inspect(d.id)}
        mac = #{inspect(d.mac)}
        oui_vendor = #{inspect(d.oui_vendor || "")}
        hostname = #{inspect(d.hostname || "")}
        fingerprint_v4_id = #{inspect(d.fingerprint_v4_id || "")}
        fingerprint_v6_id = #{inspect(d.fingerprint_v6_id || "")}
        profile_id = #{inspect(d.profile_id || "")}
        profile_confidence = #{d.profile_confidence}
        first_seen = #{DateTime.to_iso8601(d.first_seen)}
        last_seen = #{DateTime.to_iso8601(d.last_seen)}
        observation_count = #{d.observation_count}
        ipv4_addresses = [#{v4}]
        ipv6_addresses = [#{v6}]
        """
      end)
      |> Enum.join("\n")

    File.write!(path, content)
  rescue
    error ->
      Logger.warning("Failed to save devices: #{inspect(error)}")
  end

  defp read_toml(path) do
    if File.exists?(path) do
      Toml.decode_file(path)
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

  defp parse_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  defp parse_datetime(_), do: DateTime.utc_now()

  defp normalize_mac(mac), do: String.downcase(mac)
end
