defmodule YellowDog.Dhcpv4.PoolStore do
  @moduledoc """
  Persistence layer for DHCPv4 address pool definitions.

  Uses an index plus individual pool files:
  - Index file: `data/dhcpv4/pools.toml` - lists all pool names
  - Legacy pool files: `data/dhcpv4/pools/{pool_name}.toml`
  - Control snapshots:
    `data/dhcpv4/.pool-snapshots/{snapshot}/pools/{pool_name}.toml`

  A control snapshot is committed by atomically replacing the index with a
  pointer to a fully staged immutable generation. Legacy indexes remain
  readable, and legacy writers preserve snapshot mode after the first control
  commit. This architecture allows:
  - Quick loading of pool list without reading all configs
  - Independent pool configuration files
  - All-or-nothing control snapshot updates
  """

  use YellowDog.Data.Collection

  import Bitwise

  alias YellowDog.Dhcpv4.{AddressPool, Ipv4Util}
  import YellowDog.Config.TomlHelpers

  @snapshot_directory ".pool-snapshots"
  @snapshot_id_pattern ~r/\A[0-9a-f]{32}\z/

  defcollection(:dhcpv4_pools,
    key_field: :name,
    adapter: YellowDog.Data.Store.Ets,
    persistence: [strategy: :toml, path: "data/dhcpv4/pools.toml"]
  )

  @type pool_config :: %{
          name: String.t(),
          ranges: [{AddressPool.ip_address(), AddressPool.ip_address()}] | nil,
          range_start: String.t() | nil,
          range_end: String.t() | nil,
          network: String.t() | nil,
          excluded_ranges: list() | nil,
          subnet_mask: String.t() | nil,
          gateway: String.t() | nil,
          dns_servers: [String.t()] | nil,
          domain_name: String.t() | nil,
          lease_time: pos_integer() | nil,
          max_leases: pos_integer() | nil,
          enabled: boolean()
        }

  @doc """
  Loads all pools from storage.

  Reads the index file to get pool names, then loads each pool's configuration
  from its individual file.

  ## Returns
  - `{:ok, [pool_config]}` on success
  - `{:error, reason}` on failure
  """
  @spec load_pools() :: {:ok, [pool_config()]} | {:error, term()}
  def load_pools do
    load_pools(default_index_path())
  end

  @spec load_pools(String.t()) :: {:ok, [pool_config()]} | {:error, term()}
  def load_pools(index_path) do
    with {:ok, index} <- load_pool_index(index_path),
         {:ok, pools} <- load_indexed_pools(index_path, index) do
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :pool_store, :loaded],
        %{pool_count: length(pools)},
        %{index_path: index_path}
      )

      {:ok, pools}
    end
  end

  @doc """
  Loads the pool index file.

  ## Parameters
  - `index_path` - Path to the index file

  ## Returns
  - `{:ok, [pool_name]}` list of pool names
  - `{:error, reason}` on failure
  """
  @spec load_index(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def load_index(index_path) do
    with {:ok, index} <- load_pool_index(index_path) do
      {:ok, index.pool_names}
    end
  end

  @doc """
  Saves a single pool to storage.

  Updates both the index file and the pool's individual file.

  ## Parameters
  - `pool` - Pool configuration map

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_pool(pool_config()) :: :ok | {:error, term()}
  def save_pool(pool) do
    pool_name = pool[:name] || pool.name

    with :ok <- persist_pool(pool, pool_name) do
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :pool_store, :pool_saved],
        %{count: 1},
        %{pool_name: pool_name}
      )

      :ok
    end
  end

  @doc """
  Removes a pool from storage.

  Removes both the pool file and updates the index.

  ## Parameters
  - `pool_name` - Name of the pool to remove

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec remove_pool(String.t()) :: :ok | {:error, term()}
  def remove_pool(pool_name) do
    with :ok <- persist_pool_removal(pool_name) do
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :pool_store, :pool_removed],
        %{count: 1},
        %{pool_name: pool_name}
      )

      :ok
    end
  end

  @doc """
  Saves all pools to storage (batch operation).

  Recreates the index and saves all pool files.

  ## Parameters
  - `pools` - List of pool configurations

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_all_pools([pool_config()]) :: :ok | {:error, term()}
  def save_all_pools(pools) do
    with {:ok, index} <- load_pool_index(default_index_path()) do
      if index.snapshot do
        persist_complete_snapshot(pools)
      else
        save_all_pools_legacy(pools)
      end
    end
  end

  @doc """
  Gets the default index file path.
  """
  @spec default_index_path() :: String.t()
  def default_index_path do
    Path.join(get_data_dir(), "pools.toml")
  end

  @doc """
  Gets the default file path (alias for default_index_path for backwards compatibility).
  """
  @spec default_file_path() :: String.t()
  def default_file_path do
    default_index_path()
  end

  @doc """
  Gets the pools directory path.
  """
  @spec pools_directory() :: String.t()
  def pools_directory do
    Path.join(get_data_dir(), "pools")
  end

  @doc """
  Validates a pool configuration.

  ## Parameters
  - `pool` - Pool configuration map

  ## Returns
  - `:ok` if valid
  - `{:error, reason}` if invalid
  """
  @spec validate_pool(map()) :: :ok | {:error, String.t()}
  def validate_pool(pool) do
    with :ok <- validate_required_fields(pool),
         :ok <- validate_name(pool[:name] || pool["name"]),
         :ok <- validate_ip_range(pool) do
      :ok
    end
  end

  @doc false
  @spec control_snapshot() :: {:ok, [pool_config()]} | {:error, term()}
  def control_snapshot, do: load_pools()

  @doc false
  @spec control_validate_pool(pool_config()) :: :ok | {:error, term()}
  def control_validate_pool(pool) do
    result =
      with :ok <- validate_pool(pool),
           :ok <- validate_canonical_network_cidr(pool),
           {:ok, _address_pool} <- AddressPool.new(pool) do
        :ok
      end

    case result do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid}
    end
  end

  @doc false
  @spec control_persist_snapshot([pool_config()]) :: :ok | {:error, term()}
  def control_persist_snapshot(pools) when is_list(pools) do
    with :ok <- validate_control_snapshot(pools) do
      persist_complete_snapshot(pools)
    end
  end

  def control_persist_snapshot(_pools), do: {:error, :invalid_snapshot}

  # Private functions

  defp validate_control_snapshot(pools) do
    Enum.reduce_while(pools, :ok, fn pool, :ok ->
      case control_validate_pool(pool) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_canonical_network_cidr(pool) do
    network = get_value(pool, [:network, "network"])

    if canonical_network_cidr?(network), do: :ok, else: {:error, :invalid}
  end

  defp canonical_network_cidr?(network) when is_binary(network) do
    with [address, prefix_text] <- String.split(network, "/", parts: 2),
         {:ok, address} <- Ipv4Util.parse(address),
         {prefix, ""} <- Integer.parse(prefix_text),
         true <- prefix >= 0 and prefix <= 32 do
      address = Ipv4Util.to_integer(address)
      mask = if prefix == 0, do: 0, else: 0xFFFFFFFF <<< (32 - prefix) &&& 0xFFFFFFFF
      (address &&& mask) == address
    else
      _ -> false
    end
  end

  defp canonical_network_cidr?(_network), do: false

  defp get_data_dir do
    # Get base data directory from application env or use default
    base_dir = Application.get_env(:yellow_dog, :data_dir) || "data"
    Path.join(base_dir, "dhcpv4")
  end

  defp ensure_directories do
    pools_dir = pools_directory()

    case File.mkdir_p(pools_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp load_pool_index(index_path) do
    case File.read(index_path) do
      {:ok, content} ->
        decode_pool_index(content)

      {:error, :enoent} ->
        {:ok, %{pool_names: [], snapshot: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_pool_index(content) do
    case Toml.decode(content) do
      {:ok, data} ->
        with {:ok, snapshot} <- extract_snapshot_id(data) do
          {:ok, %{pool_names: extract_pool_names(data), snapshot: snapshot}}
        end

      {:error, reason} ->
        {:error, {:toml_parse_error, reason}}
    end
  end

  defp extract_snapshot_id(data) do
    case Map.get(data, "snapshot") do
      nil ->
        {:ok, nil}

      snapshot when is_binary(snapshot) ->
        if Regex.match?(@snapshot_id_pattern, snapshot),
          do: {:ok, snapshot},
          else: {:error, :invalid_snapshot_reference}

      _snapshot ->
        {:error, :invalid_snapshot_reference}
    end
  end

  defp load_indexed_pools(index_path, %{pool_names: pool_names, snapshot: nil}) do
    pools_dir = Path.join(Path.dirname(index_path), "pools")

    pools =
      for name <- pool_names,
          pool_path = Path.join(pools_dir, "#{name}.toml"),
          {:ok, pool} <- [load_pool_file(pool_path, name)],
          do: pool

    {:ok, pools}
  end

  defp load_indexed_pools(index_path, %{pool_names: pool_names, snapshot: snapshot}) do
    pools_dir = snapshot_pools_directory(index_path, snapshot)
    load_pool_files_strict(pool_names, pools_dir)
  end

  defp load_pool_files_strict(pool_names, pools_dir) do
    Enum.reduce_while(pool_names, {:ok, []}, fn name, {:ok, pools} ->
      pool_path = Path.join(pools_dir, "#{name}.toml")

      case load_pool_file(pool_path, name) do
        {:ok, pool} ->
          {:cont, {:ok, [pool | pools]}}

        {:error, reason} ->
          {:halt, {:error, {:snapshot_pool_load_failed, name, reason}}}
      end
    end)
    |> case do
      {:ok, pools} -> {:ok, Enum.reverse(pools)}
      {:error, _reason} = error -> error
    end
  end

  defp persist_pool(pool, pool_name) do
    with {:ok, index} <- load_pool_index(default_index_path()) do
      if index.snapshot do
        with {:ok, pools} <- load_indexed_pools(default_index_path(), index) do
          persist_complete_snapshot(upsert_pool(pools, pool_name, pool))
        end
      else
        with :ok <- ensure_directories(),
             :ok <- save_pool_file(pool),
             :ok <- add_to_index(pool_name) do
          :ok
        end
      end
    end
  end

  defp upsert_pool(pools, pool_name, pool) do
    case Enum.find_index(pools, &(pool_config_name(&1) == pool_name)) do
      nil -> pools ++ [pool]
      index -> List.replace_at(pools, index, pool)
    end
  end

  defp persist_pool_removal(pool_name) do
    with {:ok, index} <- load_pool_index(default_index_path()) do
      if index.snapshot do
        with {:ok, pools} <- load_indexed_pools(default_index_path(), index) do
          candidate = Enum.reject(pools, &(pool_config_name(&1) == pool_name))

          if length(candidate) == length(pools),
            do: :ok,
            else: persist_complete_snapshot(candidate)
        end
      else
        pool_path = Path.join(pools_directory(), "#{pool_name}.toml")

        with :ok <- remove_from_index(pool_name),
             :ok <- delete_pool_file(pool_path) do
          :ok
        end
      end
    end
  end

  defp save_all_pools_legacy(pools) do
    with :ok <- ensure_directories() do
      results =
        Enum.map(pools, fn pool ->
          {pool_config_name(pool), save_pool_file(pool)}
        end)

      errors = Enum.filter(results, fn {_name, result} -> result != :ok end)

      if errors == [] do
        save_index(Enum.map(pools, &pool_config_name/1))
      else
        {:error, {:save_errors, errors}}
      end
    end
  end

  defp persist_complete_snapshot(pools) do
    pool_names = Enum.map(pools, &pool_config_name/1)

    if Enum.uniq(pool_names) == pool_names do
      stage_and_commit_snapshot(pools, pool_names)
    else
      {:error, :duplicate_pool_names}
    end
  end

  defp stage_and_commit_snapshot(pools, pool_names) do
    snapshot = snapshot_id()
    snapshot_dir = snapshot_directory(default_index_path(), snapshot)
    pools_dir = Path.join(snapshot_dir, "pools")

    result =
      with :ok <- make_snapshot_directory(pools_dir),
           :ok <- save_snapshot_pool_files(pools, pools_dir),
           {:ok, _staged_pools} <- load_pool_files_strict(pool_names, pools_dir),
           :ok <- save_snapshot_index(pool_names, snapshot) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        File.rm_rf(snapshot_dir)
        error
    end
  end

  defp make_snapshot_directory(pools_dir) do
    case File.mkdir_p(pools_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp save_snapshot_pool_files(pools, pools_dir) do
    Enum.reduce_while(pools, :ok, fn pool, :ok ->
      case save_pool_file(pool, pools_dir) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp save_snapshot_index(pool_names, snapshot) do
    content = """
    # DHCPv4 Pool Snapshot Index
    # The snapshot directory is immutable; replacing this index commits the snapshot.

    snapshot = #{encode_toml_string(snapshot)}
    pools = #{inspect(pool_names)}
    """

    atomic_write(default_index_path(), content)
  end

  defp snapshot_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp snapshot_directory(index_path, snapshot) do
    Path.join([Path.dirname(index_path), @snapshot_directory, snapshot])
  end

  defp snapshot_pools_directory(index_path, snapshot) do
    Path.join(snapshot_directory(index_path, snapshot), "pools")
  end

  defp pool_config_name(pool), do: get_value(pool, [:name, "name"])

  defp extract_pool_names(data) do
    # Support multiple formats:
    # 1. pools = ["name1", "name2"]
    # 2. [[pool]] with name field
    case Map.get(data, "pools") do
      pools when is_list(pools) ->
        # Format 1: simple list of names
        Enum.filter(pools, &is_binary/1)

      _ ->
        # Format 2: [[pool]] array
        case Map.get(data, "pool") do
          pools when is_list(pools) ->
            for p <- pools, name = p["name"] || p[:name], is_binary(name), do: name

          pool when is_map(pool) ->
            name = pool["name"] || pool[:name]
            if is_binary(name), do: [name], else: []

          _ ->
            []
        end
    end
  end

  defp load_pool_file(path, pool_name) do
    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, data} ->
            pool = normalize_pool_keys(data)
            {:ok, Map.put(pool, :name, pool_name)}

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :pool_store, :pool_parse_error],
              %{count: 1},
              %{pool_name: pool_name, reason: inspect(reason)}
            )

            {:error, {:toml_parse_error, reason}}
        end

      {:error, :enoent} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :pool_store, :pool_file_missing],
          %{count: 1},
          %{pool_name: pool_name, path: path}
        )

        {:error, :file_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_pool_file(pool), do: save_pool_file(pool, pools_directory())

  defp save_pool_file(pool, pools_dir) do
    pool_name = pool[:name] || pool.name
    pool_path = Path.join(pools_dir, "#{pool_name}.toml")
    content = pool_to_toml(pool)

    case atomic_write(pool_path, content) do
      :ok -> :ok
      error -> error
    end
  end

  defp delete_pool_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp save_index(pool_names) do
    index_path = default_index_path()

    content = """
    # DHCPv4 Pool Index
    # This file lists all configured address pools.
    # Each pool's configuration is stored in pools/{name}.toml

    pools = #{inspect(pool_names)}
    """

    atomic_write(index_path, content)
  end

  defp add_to_index(pool_name) do
    index_path = default_index_path()

    case load_index(index_path) do
      {:ok, names} ->
        if pool_name in names do
          :ok
        else
          save_index(names ++ [pool_name])
        end

      {:error, _} ->
        save_index([pool_name])
    end
  end

  defp remove_from_index(pool_name) do
    index_path = default_index_path()

    case load_index(index_path) do
      {:ok, names} ->
        new_names = Enum.reject(names, &(&1 == pool_name))
        save_index(new_names)

      {:error, _} ->
        :ok
    end
  end

  defp normalize_pool_keys(pool) when is_map(pool) do
    %{
      name: get_value(pool, [:name, "name"], "default"),
      network: get_value(pool, [:network, "network"]),
      range_start: get_value(pool, [:range_start, "range_start"]),
      range_end: get_value(pool, [:range_end, "range_end"]),
      ranges: get_list(pool, [:ranges, "ranges"]),
      excluded_ranges: get_list(pool, [:excluded_ranges, "excluded_ranges"]),
      subnet_mask: get_value(pool, [:subnet_mask, "subnet_mask"], "255.255.255.0"),
      gateway: get_value(pool, [:gateway, "gateway"]),
      dns_servers: get_list(pool, [:dns_servers, "dns_servers"], []),
      domain_name: get_value(pool, [:domain_name, "domain_name", :domain, "domain"]),
      lease_time: get_integer(pool, [:lease_time, "lease_time"], 86400),
      max_leases: get_integer(pool, [:max_leases, "max_leases"], 1000),
      static_reservations: get_map(pool, [:static_reservations, "static_reservations"], %{}),
      enabled: get_boolean(pool, [:enabled, "enabled"], true)
    }
  end

  defp validate_required_fields(pool) do
    # Network CIDR is mandatory
    network = get_value(pool, [:network, "network"])

    if network do
      with :ok <- validate_network_cidr(network) do
        # Need either ranges or range_start/range_end
        has_ranges = get_value(pool, [:ranges, "ranges"])

        has_legacy =
          get_value(pool, [:range_start, "range_start"]) &&
            get_value(pool, [:range_end, "range_end"])

        if has_ranges || has_legacy do
          :ok
        else
          {:error, "Pool must have either ranges or range_start/range_end"}
        end
      end
    else
      {:error, "Network CIDR is required (e.g., '192.168.1.0/24')"}
    end
  end

  defp validate_network_cidr(network) when is_binary(network) do
    case String.split(network, "/") do
      [ip, prefix] ->
        with {:ok, _} <- Ipv4Util.parse(ip),
             {prefix_int, ""} <- Integer.parse(prefix),
             true <- prefix_int >= 0 and prefix_int <= 32 do
          :ok
        else
          _ ->
            {:error, "Invalid network CIDR format: #{network}. Expected format: '192.168.1.0/24'"}
        end

      _ ->
        {:error, "Invalid network CIDR format: #{network}. Expected format: '192.168.1.0/24'"}
    end
  end

  defp validate_network_cidr(_), do: {:error, "Network CIDR must be a string"}

  defp validate_name(nil), do: {:error, "Pool name is required"}
  defp validate_name(""), do: {:error, "Pool name cannot be empty"}
  defp validate_name(name) when is_binary(name), do: :ok
  defp validate_name(_), do: {:error, "Pool name must be a string"}

  defp validate_ip_range(pool) do
    range_start = pool[:range_start] || pool["range_start"]
    range_end = pool[:range_end] || pool["range_end"]

    cond do
      range_start && range_end ->
        with {:ok, _} <- Ipv4Util.parse(range_start),
             {:ok, _} <- Ipv4Util.parse(range_end) do
          :ok
        end

      true ->
        # Using ranges format, skip validation for now
        :ok
    end
  end

  defp pool_to_toml(pool) do
    dns_line =
      if pool[:dns_servers] && pool[:dns_servers] != [] do
        dns_list =
          Enum.map_join(pool[:dns_servers], ", ", fn ip ->
            ip |> Ipv4Util.format() |> encode_toml_string()
          end)

        ["dns_servers = [#{dns_list}]"]
      else
        []
      end

    range_lines =
      if pool[:range_start] do
        [
          "range_start = #{encode_toml_string(Ipv4Util.format(pool[:range_start]))}",
          "range_end = #{encode_toml_string(Ipv4Util.format(pool[:range_end]))}"
        ]
      else
        []
      end

    lines =
      List.flatten([
        "# DHCPv4 Pool Configuration",
        "# Pool: #{pool[:name] || pool.name}",
        "",
        "enabled = #{get_boolean(pool, [:enabled, "enabled"], true)}",
        if(pool[:network], do: "network = #{encode_toml_string(pool[:network])}", else: []),
        range_lines,
        if(pool[:lease_time], do: "lease_time = #{pool[:lease_time]}", else: []),
        if(pool[:max_leases], do: "max_leases = #{pool[:max_leases]}", else: []),
        if(pool[:subnet_mask],
          do: "subnet_mask = #{encode_toml_string(pool[:subnet_mask])}",
          else: []
        ),
        if(pool[:gateway],
          do: "gateway = #{encode_toml_string(Ipv4Util.format(pool[:gateway]))}",
          else: []
        ),
        if(pool[:domain_name],
          do: "domain_name = #{encode_toml_string(pool[:domain_name])}",
          else: []
        ),
        dns_line
      ])

    Enum.join(lines, "\n") <> "\n"
  end

  # ============================================================================
  # Lease Persistence Functions
  # ============================================================================

  alias YellowDog.Dhcpv4.Lease
  alias YellowDog.DHCP.SafeWriter

  @doc """
  Gets the leases directory path.
  """
  @spec leases_directory() :: String.t()
  def leases_directory do
    Path.join(get_data_dir(), "leases")
  end

  @doc """
  Loads leases for a specific pool.

  ## Parameters
  - `pool_name` - Name of the pool

  ## Returns
  - `{:ok, [Lease.t()]}` - List of leases
  - `{:error, reason}` - On failure
  """
  @spec load_leases(String.t()) :: {:ok, [Lease.t()]} | {:error, term()}
  def load_leases(pool_name) do
    lease_path = Path.join(leases_directory(), "#{pool_name}.toml")

    case File.read(lease_path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, data} ->
            leases =
              for entry <- Map.get(data, "leases", []),
                  lease = parse_lease_entry(entry),
                  not is_nil(lease),
                  do: lease

            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :pool_store, :leases_loaded],
              %{count: length(leases)},
              %{pool_name: pool_name}
            )

            {:ok, leases}

          {:error, reason} ->
            {:error, {:toml_parse_error, reason}}
        end

      {:error, :enoent} ->
        # No lease file yet - return empty list
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Saves leases for a specific pool.

  Uses SafeWriter for atomic, validated writes.

  ## Parameters
  - `pool_name` - Name of the pool
  - `leases` - List of Lease structs

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_leases(String.t(), [Lease.t()]) :: :ok | {:error, term()}
  def save_leases(pool_name, leases) do
    lease_path = Path.join(leases_directory(), "#{pool_name}.toml")

    # Ensure directory exists
    File.mkdir_p!(leases_directory())

    content = leases_to_toml(pool_name, leases)

    case SafeWriter.write(lease_path, content, validator: &SafeWriter.validate_toml/1) do
      :ok ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :pool_store, :leases_saved],
          %{count: length(leases)},
          %{pool_name: pool_name}
        )

        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :pool_store, :leases_save_failed],
          %{count: 1},
          %{pool_name: pool_name, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Loads all leases from all pools.

  ## Returns
  - `{:ok, %{pool_name => [Lease.t()]}}` - Map of pool names to leases
  """
  @spec load_all_leases() :: {:ok, %{String.t() => [Lease.t()]}}
  def load_all_leases do
    leases_dir = leases_directory()

    case File.ls(leases_dir) do
      {:ok, files} ->
        leases_map =
          for file <- files,
              String.ends_with?(file, ".toml"),
              pool_name = Path.rootname(file),
              {:ok, leases} <- [load_leases(pool_name)],
              into: %{},
              do: {pool_name, leases}

        {:ok, leases_map}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _reason} ->
        {:ok, %{}}
    end
  end

  @doc """
  Deletes lease file for a pool.

  ## Parameters
  - `pool_name` - Name of the pool

  ## Returns
  - `:ok` on success
  """
  @spec delete_leases(String.t()) :: :ok
  def delete_leases(pool_name) do
    lease_path = Path.join(leases_directory(), "#{pool_name}.toml")
    File.rm(lease_path)
    :ok
  end

  defp parse_lease_entry(entry) when is_map(entry) do
    case Lease.from_toml_map(entry) do
      {:ok, lease} -> lease
      {:error, _} -> nil
    end
  end

  defp parse_lease_entry(_), do: nil

  defp leases_to_toml(pool_name, leases) do
    header = """
    # DHCPv4 Leases for pool: #{pool_name}
    # Auto-generated - do not edit while service running
    # Last updated: #{DateTime.to_iso8601(DateTime.utc_now())}

    """

    lease_entries = Enum.map_join(leases, "\n", &lease_to_toml_entry/1)

    header <> lease_entries
  end

  defp lease_to_toml_entry(%Lease{} = lease) do
    map = Lease.to_toml_map(lease)

    """
    [[leases]]
    ip = "#{map["ip"]}"
    mac = "#{map["mac"]}"
    pool_name = "#{map["pool_name"]}"
    starts_at = "#{map["starts_at"]}"
    expires_at = "#{map["expires_at"]}"
    state = "#{map["state"]}"
    """ <>
      maybe_field("hostname", map["hostname"]) <>
      maybe_field("client_id", map["client_id"])
  end

  defp lease_to_toml_entry(lease) when is_map(lease) do
    # Handle legacy map format
    """
    [[leases]]
    ip = "#{Ipv4Util.format(lease[:ip_address])}"
    mac = "#{format_mac_for_toml(lease[:mac_address])}"
    pool_name = "#{lease[:pool_name] || "default"}"
    starts_at = "#{format_datetime(lease[:created_at])}"
    expires_at = "#{format_datetime(lease[:expires_at])}"
    state = "#{lease[:state] || "active"}"
    """ <>
      maybe_field("hostname", lease[:hostname]) <>
      maybe_field("client_id", format_client_id(lease[:client_id]))
  end

  defp maybe_field(_name, nil), do: ""
  defp maybe_field(name, value), do: "#{name} = \"#{value}\"\n"

  defp format_mac_for_toml(mac) when is_binary(mac) do
    YellowDog.Dhcpv4.MacFormat.format(mac, case: :lower) || mac
  end

  defp format_mac_for_toml(_), do: "00:00:00:00:00:00"

  defp format_client_id(nil), do: nil
  defp format_client_id(bytes) when is_binary(bytes), do: Base.encode16(bytes, case: :lower)
end
