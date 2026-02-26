defmodule YellowDog.Dhcpv4.PoolConfig do
  @moduledoc """
  TOML-based pool configuration loader for DHCPv4.

  Loads pool definitions from TOML files with validation and transformation
  into internal format suitable for AddressPool.

  ## Configuration Format

      [[pools]]
      name = "office_network"
      enabled = true
      subnet = "192.168.1.0/24"
      ranges = ["192.168.1.100-192.168.1.200"]
      gateway = "192.168.1.1"
      dns_servers = ["8.8.8.8", "8.8.4.4"]
      domain = "office.local"
      lease_time = 86400
      max_leases = 1000
      priority = 100

      [[pools.reservations]]
      mac = "aa:bb:cc:dd:ee:ff"
      address = "192.168.1.50"
      hostname = "printer-01"
  """

  require Logger
  import Bitwise
  import YellowDog.ConfigHelpers, only: [collect_ok: 1]

  alias YellowDog.Dhcpv4.{AddressPool, Ipv4Util}

  @type pool_definition :: %{
          name: String.t(),
          enabled: boolean(),
          ranges: [{AddressPool.ip_address(), AddressPool.ip_address()}],
          subnet_mask: AddressPool.ip_address(),
          gateway: AddressPool.ip_address(),
          dns_servers: [AddressPool.ip_address()],
          domain_name: String.t() | nil,
          lease_time: pos_integer(),
          max_leases: pos_integer(),
          priority: non_neg_integer(),
          static_reservations: %{String.t() => AddressPool.ip_address()}
        }

  @default_lease_time 86400
  @default_max_leases 1000
  @default_priority 100

  @doc """
  Loads pool configurations from a TOML file.

  ## Parameters
  - `path` - Path to TOML configuration file

  ## Returns
  - `{:ok, [pool_definition()]}` - Successfully loaded pools
  - `{:error, reason}` - Failed to load or parse
  """
  @spec load(String.t()) :: {:ok, [pool_definition()]} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, config} ->
            parse_pools(config)

          {:error, reason} ->
            emit_error_telemetry(path, :parse_error, reason)
            {:error, {:parse_error, reason}}
        end

      {:error, reason} ->
        emit_error_telemetry(path, :read_error, reason)
        {:error, {:read_error, reason}}
    end
  end

  @doc """
  Loads pool configurations with fallback to defaults.

  ## Parameters
  - `path` - Path to TOML configuration file
  - `defaults` - Default pool configurations if file not found

  ## Returns
  - List of pool definitions
  """
  @spec load_with_fallback(String.t(), [pool_definition()]) :: [pool_definition()]
  def load_with_fallback(path, defaults \\ []) do
    case load(path) do
      {:ok, pools} ->
        pools

      {:error, _reason} ->
        emit_fallback_telemetry(path)
        defaults
    end
  end

  @doc """
  Validates a pool configuration map.

  ## Parameters
  - `pool_config` - Raw pool configuration map from TOML

  ## Returns
  - `{:ok, pool_definition()}` - Valid configuration
  - `{:error, reason}` - Validation failed
  """
  @spec validate(map()) :: {:ok, pool_definition()} | {:error, term()}
  def validate(pool_config) do
    with {:ok, name} <- validate_name(pool_config),
         {:ok, ranges} <- validate_ranges(pool_config),
         {:ok, subnet_mask} <- validate_subnet(pool_config),
         {:ok, gateway} <- validate_gateway(pool_config),
         {:ok, dns_servers} <- validate_dns_servers(pool_config),
         {:ok, reservations} <- validate_reservations(pool_config) do
      pool = %{
        name: name,
        enabled: Map.get(pool_config, "enabled", true),
        ranges: ranges,
        # Legacy support
        range_start: elem(hd(ranges), 0),
        range_end: elem(hd(ranges), 1),
        excluded_ranges: [],
        subnet_mask: subnet_mask,
        gateway: gateway,
        dns_servers: dns_servers,
        domain_name: Map.get(pool_config, "domain"),
        lease_time: Map.get(pool_config, "lease_time", @default_lease_time),
        max_leases: Map.get(pool_config, "max_leases", @default_max_leases),
        priority: Map.get(pool_config, "priority", @default_priority),
        static_reservations: reservations
      }

      {:ok, pool}
    end
  end

  @doc """
  Converts pool definition to AddressPool format.

  ## Parameters
  - `pool_def` - Pool definition from TOML

  ## Returns
  - Configuration map suitable for AddressPool.new/1
  """
  @spec to_address_pool_config(pool_definition()) :: map()
  def to_address_pool_config(pool_def) do
    %{
      name: pool_def.name,
      ranges: pool_def.ranges,
      range_start: pool_def[:range_start] || first_range_elem(pool_def.ranges, 0),
      range_end: pool_def[:range_end] || first_range_elem(pool_def.ranges, 1),
      excluded_ranges: pool_def[:excluded_ranges] || [],
      subnet_mask: pool_def.subnet_mask,
      gateway: pool_def.gateway,
      dns_servers: pool_def.dns_servers,
      domain_name: pool_def.domain_name,
      lease_time: pool_def.lease_time,
      static_reservations: pool_def.static_reservations
    }
  end

  defp first_range_elem([{start, _end} | _], 0), do: start
  defp first_range_elem([{_start, end_} | _], 1), do: end_
  defp first_range_elem(_, _), do: nil

  # Private functions

  defp parse_pools(%{"pools" => pools}) when is_list(pools) do
    results =
      Enum.map(pools, fn pool_config ->
        case validate(pool_config) do
          {:ok, pool} ->
            {:ok, pool}

          {:error, reason} ->
            name = Map.get(pool_config, "name", "unknown")
            emit_pool_error_telemetry(name, reason)
            {:error, {name, reason}}
        end
      end)

    case collect_ok(results) do
      {:ok, pools} ->
        emit_loaded_telemetry(length(pools))
        {:ok, pools}

      {:error, errors} ->
        {:error, {:validation_errors, errors}}
    end
  end

  defp parse_pools(_config) do
    {:error, :no_pools_defined}
  end

  defp validate_name(pool_config) do
    case Map.get(pool_config, "name") do
      nil -> {:error, :missing_name}
      name when is_binary(name) -> {:ok, name}
      _ -> {:error, :invalid_name}
    end
  end

  defp validate_ranges(pool_config) do
    case Map.get(pool_config, "ranges") do
      nil ->
        {:error, :missing_ranges}

      [] ->
        {:error, :empty_ranges}

      ranges when is_list(ranges) ->
        parsed_ranges =
          Enum.map(ranges, &parse_range_string/1)

        case collect_ok(parsed_ranges) do
          {:ok, _} = ok -> ok
          {:error, errors} -> {:error, {:invalid_ranges, errors}}
        end

      _ ->
        {:error, :invalid_ranges}
    end
  end

  defp parse_range_string(range_str) when is_binary(range_str) do
    case String.split(range_str, "-") do
      [start_str, end_str] ->
        with {:ok, start_ip} <- Ipv4Util.parse(String.trim(start_str)),
             {:ok, end_ip} <- Ipv4Util.parse(String.trim(end_str)) do
          {:ok, {start_ip, end_ip}}
        end

      _ ->
        {:error, {:invalid_range_format, range_str}}
    end
  end

  defp parse_range_string(_), do: {:error, :invalid_range_type}

  defp validate_subnet(pool_config) do
    case Map.get(pool_config, "subnet") do
      nil ->
        # Default to /24
        {:ok, {255, 255, 255, 0}}

      subnet_str when is_binary(subnet_str) ->
        parse_subnet_string(subnet_str)

      _ ->
        {:error, :invalid_subnet}
    end
  end

  defp parse_subnet_string(subnet_str) do
    case String.split(subnet_str, "/") do
      [_network, prefix_str] ->
        case Integer.parse(prefix_str) do
          {prefix_len, ""} when prefix_len >= 0 and prefix_len <= 32 ->
            mask = prefix_to_mask(prefix_len)
            {:ok, mask}

          _ ->
            {:error, {:invalid_prefix, prefix_str}}
        end

      _ ->
        {:error, {:invalid_subnet_format, subnet_str}}
    end
  end

  defp prefix_to_mask(prefix_len) do
    mask_int = bsl(0xFFFFFFFF, 32 - prefix_len) &&& 0xFFFFFFFF
    <<a, b, c, d>> = <<mask_int::32>>
    {a, b, c, d}
  end

  defp validate_gateway(pool_config) do
    case Map.get(pool_config, "gateway") do
      nil -> {:error, :missing_gateway}
      ip_str when is_binary(ip_str) -> Ipv4Util.parse(ip_str)
      _ -> {:error, :invalid_gateway}
    end
  end

  defp validate_dns_servers(pool_config) do
    case Map.get(pool_config, "dns_servers") do
      nil ->
        {:ok, []}

      servers when is_list(servers) ->
        parsed =
          Enum.map(servers, &Ipv4Util.parse/1)

        case collect_ok(parsed) do
          {:ok, _} = ok -> ok
          {:error, errors} -> {:error, {:invalid_dns_servers, errors}}
        end

      _ ->
        {:error, :invalid_dns_servers}
    end
  end

  defp validate_reservations(pool_config) do
    case Map.get(pool_config, "reservations") do
      nil ->
        {:ok, %{}}

      reservations when is_list(reservations) ->
        parsed =
          Enum.map(reservations, fn res ->
            with {:ok, mac} <- validate_mac(Map.get(res, "mac")),
                 {:ok, ip} <- Ipv4Util.parse(Map.get(res, "address", "")) do
              {:ok, {mac, ip}}
            end
          end)

        case collect_ok(parsed) do
          {:ok, pairs} -> {:ok, Map.new(pairs)}
          {:error, errors} -> {:error, {:invalid_reservations, errors}}
        end

      _ ->
        {:error, :invalid_reservations}
    end
  end

  defp validate_mac(nil), do: {:error, :missing_mac}

  defp validate_mac(mac_str) when is_binary(mac_str) do
    # Normalize MAC address format (uppercase, colon-separated)
    normalized =
      mac_str
      |> String.upcase()
      |> String.replace(["-", "."], ":")

    # Validate format
    if normalized =~ ~r/^([0-9A-F]{2}:){5}[0-9A-F]{2}$/ do
      {:ok, normalized}
    else
      {:error, {:invalid_mac_format, mac_str}}
    end
  end

  defp validate_mac(_), do: {:error, :invalid_mac_type}

  # Telemetry helpers

  defp emit_error_telemetry(path, reason, error) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :pool_config, :error],
      %{count: 1},
      %{path: path, reason: reason, error: inspect(error)}
    )
  end

  defp emit_fallback_telemetry(path) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :pool_config, :fallback],
      %{count: 1},
      %{path: path}
    )
  end

  defp emit_pool_error_telemetry(name, reason) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :pool_config, :pool_error],
      %{count: 1},
      %{pool_name: name, reason: inspect(reason)}
    )
  end

  defp emit_loaded_telemetry(count) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :pool_config, :loaded],
      %{pool_count: count},
      %{}
    )
  end
end
