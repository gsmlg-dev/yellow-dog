defmodule YellowDog.Dhcpv4.PoolStore do
  @moduledoc """
  Persistence layer for DHCPv4 address pool definitions.

  Uses a two-level storage structure:
  - Index file: `data/dhcpv4/pools.toml` - lists all pool names
  - Pool files: `data/dhcpv4/pools/{pool_name}.toml` - individual pool configs

  This architecture allows:
  - Quick loading of pool list without reading all configs
  - Independent management of each pool's configuration
  - Atomic updates to individual pools without affecting others
  """

  alias YellowDog.Dhcpv4.AddressPool
  import YellowDog.Config.TomlHelpers

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
    with {:ok, pool_names} <- load_index(index_path) do
      # Derive pools directory relative to the index file
      pools_dir = Path.join(Path.dirname(index_path), "pools")

      pools =
        for name <- pool_names,
            pool_path = Path.join(pools_dir, "#{name}.toml"),
            {:ok, pool} <- [load_pool_file(pool_path, name)],
            do: pool

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
    case File.read(index_path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, data} ->
            pools = extract_pool_names(data)
            {:ok, pools}

          {:error, reason} ->
            {:error, {:toml_parse_error, reason}}
        end

      {:error, :enoent} ->
        # Index file doesn't exist - return empty list
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
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

    with :ok <- ensure_directories(),
         :ok <- save_pool_file(pool),
         :ok <- add_to_index(pool_name) do
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
    pool_path = Path.join(pools_directory(), "#{pool_name}.toml")

    with :ok <- remove_from_index(pool_name),
         :ok <- delete_pool_file(pool_path) do
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
    with :ok <- ensure_directories() do
      # Save each pool file
      results =
        Enum.map(pools, fn pool ->
          {pool[:name] || pool.name, save_pool_file(pool)}
        end)

      # Check for errors
      errors = Enum.filter(results, fn {_, result} -> result != :ok end)

      if errors == [] do
        # Rebuild index with all pool names
        pool_names = Enum.map(pools, fn pool -> pool[:name] || pool.name end)
        save_index(pool_names)
      else
        {:error, {:save_errors, errors}}
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

  # Private functions

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
            Enum.map(pools, fn p -> p["name"] || p[:name] end)
            |> Enum.filter(&is_binary/1)

          pool when is_map(pool) ->
            [pool["name"] || pool[:name]]
            |> Enum.filter(&is_binary/1)

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

  defp save_pool_file(pool) do
    pool_name = pool[:name] || pool.name
    pool_path = Path.join(pools_directory(), "#{pool_name}.toml")
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
    network = Map.get(pool, :network) || Map.get(pool, "network")

    if network do
      with :ok <- validate_network_cidr(network) do
        # Need either ranges or range_start/range_end
        has_ranges = Map.get(pool, :ranges) || Map.get(pool, "ranges")

        has_legacy =
          (Map.get(pool, :range_start) || Map.get(pool, "range_start")) &&
            (Map.get(pool, :range_end) || Map.get(pool, "range_end"))

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
        with {:ok, _} <- parse_ipv4(ip),
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
        with {:ok, _} <- parse_ipv4(range_start),
             {:ok, _} <- parse_ipv4(range_end) do
          :ok
        end

      true ->
        # Using ranges format, skip validation for now
        :ok
    end
  end

  defp parse_ipv4(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {_, _, _, _} = ip_tuple} -> {:ok, ip_tuple}
      _ -> {:error, "Invalid IPv4 address: #{ip}"}
    end
  end

  defp parse_ipv4(ip) when is_tuple(ip) and tuple_size(ip) == 4, do: {:ok, ip}
  defp parse_ipv4(_), do: {:error, "Invalid IPv4 format"}

  defp pool_to_toml(pool) do
    dns_line =
      if pool[:dns_servers] && pool[:dns_servers] != [] do
        dns_list =
          Enum.map_join(pool[:dns_servers], ", ", fn ip ->
            ip |> format_ip_for_toml() |> encode_toml_string()
          end)

        ["dns_servers = [#{dns_list}]"]
      else
        []
      end

    range_lines =
      if pool[:range_start] do
        [
          "range_start = #{encode_toml_string(format_ip_for_toml(pool[:range_start]))}",
          "range_end = #{encode_toml_string(format_ip_for_toml(pool[:range_end]))}"
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
          do: "gateway = #{encode_toml_string(format_ip_for_toml(pool[:gateway]))}",
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

  defp format_ip_for_toml(ip) when tuple_size(ip) == 4, do: ip |> :inet.ntoa() |> to_string()
  defp format_ip_for_toml(ip) when is_binary(ip), do: ip
  defp format_ip_for_toml(nil), do: nil

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
          files
          |> Enum.filter(&String.ends_with?(&1, ".toml"))
          |> Enum.reduce(%{}, fn file, acc ->
            pool_name = Path.rootname(file)

            case load_leases(pool_name) do
              {:ok, leases} -> Map.put(acc, pool_name, leases)
              {:error, _} -> acc
            end
          end)

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
    ip = "#{format_ip_for_toml(lease[:ip_address] || lease.ip_address)}"
    mac = "#{format_mac_for_toml(lease[:mac_address] || lease.mac_address)}"
    pool_name = "#{lease[:pool_name] || lease.pool_name || "default"}"
    starts_at = "#{format_datetime(lease[:created_at] || lease.created_at)}"
    expires_at = "#{format_datetime(lease[:expires_at] || lease.expires_at)}"
    state = "#{lease[:state] || lease.state || "active"}"
    """ <>
      maybe_field("hostname", lease[:hostname] || Map.get(lease, :hostname)) <>
      maybe_field("client_id", format_client_id(lease[:client_id] || Map.get(lease, :client_id)))
  end

  defp maybe_field(_name, nil), do: ""
  defp maybe_field(name, value), do: "#{name} = \"#{value}\"\n"

  defp format_mac_for_toml(mac) when is_binary(mac) do
    YellowDog.Dhcpv4.MacFormat.format(mac, case: :lower) || mac
  end

  defp format_mac_for_toml(_), do: "00:00:00:00:00:00"

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime(unix) when is_integer(unix),
    do: DateTime.to_iso8601(DateTime.from_unix!(unix))

  defp format_datetime(_), do: DateTime.to_iso8601(DateTime.utc_now())

  defp format_client_id(nil), do: nil
  defp format_client_id(bytes) when is_binary(bytes), do: Base.encode16(bytes, case: :lower)
end
