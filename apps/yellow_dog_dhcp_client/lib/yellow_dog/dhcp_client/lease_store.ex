defmodule YellowDog.DhcpClient.LeaseStore do
  @moduledoc """
  Per-interface lease persistence backed by ETS for fast reads and periodic
  disk flush using TOML serialization.

  On startup, attempts to load a previously persisted lease from disk. If the
  lease is valid and non-expired, it is made available for the state machine
  to enter REBINDING instead of starting from INIT.

  Disk writes use a transactional pattern: write to a temporary file then
  rename, ensuring atomicity on POSIX filesystems.
  """

  use GenServer

  require Logger

  @default_lease_dir "/var/lib/yellowdog/leases"
  @flush_delay_ms 1_000

  defstruct [:interface, :table, :lease_dir, :flush_ref]

  # --- Public API ---

  @doc "Starts a lease store for the given interface."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    _interface = Keyword.fetch!(opts, :interface)
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  @doc "Stores a lease for the interface. Schedules an asynchronous disk flush."
  @spec store(GenServer.server(), String.t(), map()) :: :ok
  def store(server, interface, lease) do
    GenServer.call(server, {:store, interface, lease})
  end

  @doc "Looks up the current lease for the interface from ETS."
  @spec lookup(GenServer.server(), String.t()) :: {:ok, map()} | :not_found
  def lookup(server, interface) do
    GenServer.call(server, {:lookup, interface})
  end

  @doc "Deletes the lease for the interface from ETS and disk."
  @spec delete(GenServer.server(), String.t()) :: :ok
  def delete(server, interface) do
    GenServer.call(server, {:delete, interface})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    interface = Keyword.fetch!(opts, :interface)
    lease_dir = Keyword.get(opts, :lease_dir, @default_lease_dir)

    table = :ets.new(:dhcp_client_leases, [:set, :protected])

    state = %__MODULE__{
      interface: interface,
      table: table,
      lease_dir: lease_dir,
      flush_ref: nil
    }

    state = load_persisted_lease(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:store, interface, lease}, _from, state) do
    :ets.insert(state.table, {interface, lease})
    state = schedule_flush(state, interface)
    {:reply, :ok, state}
  end

  def handle_call({:lookup, interface}, _from, state) do
    result =
      case :ets.lookup(state.table, interface) do
        [{^interface, lease}] -> {:ok, lease}
        [] -> :not_found
      end

    {:reply, result, state}
  end

  def handle_call({:delete, interface}, _from, state) do
    :ets.delete(state.table, interface)
    delete_lease_file(state.lease_dir, interface)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:flush, interface}, state) do
    flush_to_disk(state, interface)
    {:noreply, %{state | flush_ref: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    case :ets.lookup(state.table, state.interface) do
      [{interface, _lease}] -> flush_to_disk(state, interface)
      [] -> :ok
    end

    :ok
  end

  # --- Disk persistence ---

  defp load_persisted_lease(state) do
    path = lease_path(state.lease_dir, state.interface)

    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, map} ->
            lease = deserialize_lease(map)

            if lease_valid?(lease) do
              :ets.insert(state.table, {state.interface, lease})
              Logger.debug("Loaded persisted lease for #{state.interface}")
            else
              Logger.debug("Discarding expired lease for #{state.interface}")
              delete_lease_file(state.lease_dir, state.interface)
            end

          {:error, reason} ->
            Logger.warning("Failed to parse lease file #{path}: #{inspect(reason)}")
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to read lease file #{path}: #{inspect(reason)}")
    end

    state
  end

  defp flush_to_disk(state, interface) do
    case :ets.lookup(state.table, interface) do
      [{^interface, lease}] ->
        path = lease_path(state.lease_dir, interface)
        tmp_path = path <> ".tmp"
        content = serialize_lease(lease)

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(tmp_path, content),
             :ok <- File.rename(tmp_path, path) do
          :ok
        else
          {:error, reason} ->
            Logger.warning("Failed to persist lease for #{interface}: #{inspect(reason)}")
            File.rm(tmp_path)
            :ok
        end

      [] ->
        :ok
    end
  end

  defp schedule_flush(state, interface) do
    if state.flush_ref do
      Process.cancel_timer(state.flush_ref)
    end

    ref = Process.send_after(self(), {:flush, interface}, @flush_delay_ms)
    %{state | flush_ref: ref}
  end

  defp delete_lease_file(lease_dir, interface) do
    path = lease_path(lease_dir, interface)
    File.rm(path)
    :ok
  end

  defp lease_path(lease_dir, interface) do
    Path.join(lease_dir, "#{interface}.lease")
  end

  # --- Serialization ---

  defp serialize_lease(lease) do
    map = %{
      "ip" => format_ip(lease.ip),
      "subnet_mask" => format_ip(lease.subnet_mask),
      "server_ip" => format_ip(lease.server_ip),
      "lease_time" => lease.lease_time,
      "t1" => lease.t1,
      "t2" => lease.t2,
      "obtained_at" => DateTime.to_iso8601(lease.obtained_at),
      "xid" => lease.xid,
      "yellowdog_server" => Map.get(lease, :yellowdog_server, false)
    }

    map
    |> maybe_put("router", format_ip_optional(lease.router))
    |> maybe_put("domain_name", lease.domain_name)
    |> maybe_put("mtu", lease.mtu)
    |> maybe_put("control_url", lease.control_url)
    |> maybe_put("control_url_fallback", lease.control_url_fallback)
    |> maybe_put("auth_token", lease.auth_token)
    |> maybe_put("server_id", lease.server_id)
    |> maybe_put("cluster_id", lease.cluster_id)
    |> maybe_put_list("dns_servers", Enum.map(lease.dns_servers, &format_ip/1))
    |> maybe_put_list("ntp_servers", Enum.map(lease.ntp_servers, &format_ip/1))
    |> encode_toml()
  end

  defp encode_toml(map) do
    Enum.map_join(map, "\n", fn {key, value} ->
      "#{key} = #{encode_toml_value(value)}"
    end) <> "\n"
  end

  defp encode_toml_value(value) when is_binary(value), do: ~s("#{value}")
  defp encode_toml_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_toml_value(value) when is_boolean(value), do: Atom.to_string(value)

  defp encode_toml_value(value) when is_list(value) do
    inner = Enum.map_join(value, ", ", &encode_toml_value/1)
    "[#{inner}]"
  end

  defp deserialize_lease(map) do
    %{
      ip: parse_ip(Map.get(map, "ip")),
      subnet_mask: parse_ip(Map.get(map, "subnet_mask")),
      router: parse_ip_optional(Map.get(map, "router")),
      dns_servers: parse_ip_list(Map.get(map, "dns_servers", [])),
      ntp_servers: parse_ip_list(Map.get(map, "ntp_servers", [])),
      server_ip: parse_ip(Map.get(map, "server_ip")),
      lease_time: Map.get(map, "lease_time"),
      t1: Map.get(map, "t1"),
      t2: Map.get(map, "t2"),
      domain_name: Map.get(map, "domain_name"),
      mtu: Map.get(map, "mtu"),
      obtained_at: parse_datetime(Map.get(map, "obtained_at")),
      xid: Map.get(map, "xid"),
      yellowdog_server: Map.get(map, "yellowdog_server", false),
      control_url: Map.get(map, "control_url"),
      control_url_fallback: Map.get(map, "control_url_fallback"),
      auth_token: Map.get(map, "auth_token"),
      server_id: Map.get(map, "server_id"),
      cluster_id: Map.get(map, "cluster_id"),
      vendor_options: %{},
      raw_options: %{}
    }
  end

  defp lease_valid?(lease) do
    case lease do
      %{obtained_at: %DateTime{} = obtained, lease_time: lt} when is_integer(lt) and lt > 0 ->
        expires = DateTime.add(obtained, lt, :second)
        DateTime.before?(DateTime.utc_now(), expires)

      _ ->
        false
    end
  end

  # --- IP formatting helpers ---

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(nil), do: "0.0.0.0"

  defp format_ip_optional(nil), do: nil
  defp format_ip_optional(ip), do: format_ip(ip)

  defp parse_ip(nil), do: {0, 0, 0, 0}

  defp parse_ip(str) when is_binary(str) do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, ip} -> ip
      {:error, _} -> {0, 0, 0, 0}
    end
  end

  defp parse_ip_optional(nil), do: nil
  defp parse_ip_optional(str), do: parse_ip(str)

  defp parse_ip_list(list) when is_list(list), do: Enum.map(list, &parse_ip/1)
  defp parse_ip_list(_), do: []

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_list(map, _key, []), do: map
  defp maybe_put_list(map, key, list), do: Map.put(map, key, list)
end
