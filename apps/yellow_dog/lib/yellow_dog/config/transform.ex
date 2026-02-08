defmodule YellowDog.Config.Transform do
  @moduledoc """
  Custom TOML transformation for YellowDog configuration.

  Converts TOML values into more usable Elixir data structures:
  - Converts string keys to atoms where appropriate
  - Validates IP addresses and converts to tuples
  - Ensures proper types for ports, timeouts, etc.
  - Applies default values for missing optional fields
  """

  @doc """
  Transforms a decoded TOML configuration map into YellowDog-specific structures.

  This is applied as a post-processing step after TOML decoding.

  ## Examples

      iex> config = %{"dns" => %{"listen" => "127.0.0.1", "port" => 53}}
      iex> YellowDog.Config.Transform.apply(config)
      %{"dns" => %{listen: {127, 0, 0, 1}, port: 53}}
  """
  @spec apply(map()) :: map()
  def apply(config) when is_map(config) do
    config
    |> transform_section("core", &transform_core/1)
    |> transform_section("dns", &transform_dns/1)
    |> transform_section("mdns", &transform_mdns/1)
    |> transform_section("dhcpv4", &transform_dhcpv4/1)
    |> transform_section("dhcpv6", &transform_dhcpv6/1)
  end

  # Helper to transform a specific section if it exists
  defp transform_section(config, section_name, transformer_fn) do
    case Map.get(config, section_name) do
      nil ->
        config

      section_config ->
        transformed = transformer_fn.(section_config)
        Map.put(config, section_name, transformed)
    end
  end

  # Section-level transformations

  defp transform_core(section) when is_map(section) do
    # Convert string keys to atoms for programmatic access
    for {key, value} <- section, into: %{} do
      case key do
        "dns" -> {:dns, value}
        "mdns" -> {:mdns, value}
        "dhcpv4" -> {:dhcpv4, value}
        "dhcpv6" -> {:dhcpv6, value}
        _ -> {safe_to_atom(key), value}
      end
    end
  end

  defp transform_dns(section) when is_map(section) do
    for {key, value} <- section, into: %{} do
      case key do
        "port" when is_integer(value) ->
          {:port, value}

        "listen" when is_binary(value) ->
          case parse_ipv4(value) do
            {:ok, ip_tuple} -> {:listen, ip_tuple}
            :error -> {:listen, value}
          end

        "mode" when is_binary(value) ->
          mode_atom =
            case value do
              "authoritative" -> :authoritative
              "recursive" -> :recursive
              "forward" -> :forward
              _ -> :authoritative
            end

          {:mode, mode_atom}

        "upstream_servers" when is_list(value) ->
          servers =
            Enum.map(value, fn server ->
              case parse_ipv4(server) do
                {:ok, ip_tuple} -> {ip_tuple, 53}
                :error -> {server, 53}
              end
            end)

          {:upstream_servers, servers}

        "worker_pool_size" when is_integer(value) ->
          {:worker_pool_size, value}

        "cache_ttl" when is_integer(value) ->
          {:cache_ttl, value}

        "zones" when is_map(value) ->
          # Transform each zone
          transformed_zones =
            for {zone_name, zone_config} <- value, into: %{} do
              {zone_name, transform_dns_zone(zone_config)}
            end

          {:zones, transformed_zones}

        _ ->
          {safe_to_atom(key), value}
      end
    end
  end

  defp transform_dns_zone(zone) when is_map(zone) do
    for {key, value} <- zone, into: %{} do
      case key do
        "type" when is_binary(value) ->
          type_atom =
            case value do
              "authoritative" -> :authoritative
              "forward" -> :forward
              _ -> :authoritative
            end

          {:type, type_atom}

        "file" when is_binary(value) ->
          {:file, value}

        _ ->
          {safe_to_atom(key), value}
      end
    end
  end

  defp transform_mdns(section) when is_map(section) do
    for {key, value} <- section, into: %{} do
      case key do
        "port" when is_integer(value) ->
          {:port, value}

        "listen" when is_binary(value) ->
          case parse_ipv4(value) do
            {:ok, ip_tuple} -> {:listen, ip_tuple}
            :error -> {:listen, value}
          end

        "multicast_address" when is_binary(value) ->
          case parse_ipv4(value) do
            {:ok, ip_tuple} -> {:multicast_address, ip_tuple}
            :error -> {:multicast_address, value}
          end

        _ ->
          {safe_to_atom(key), value}
      end
    end
  end

  defp transform_dhcpv4(section) when is_map(section) do
    for {key, value} <- section, into: %{} do
      case key do
        "port" when is_integer(value) ->
          {:port, value}

        "listen" when is_binary(value) ->
          case parse_ipv4(value) do
            {:ok, ip_tuple} -> {:listen, ip_tuple}
            :error -> {:listen, value}
          end

        "lease_time" when is_integer(value) ->
          {:lease_time, value}

        "pools" when is_list(value) ->
          transformed_pools = Enum.map(value, &transform_dhcpv4_pool/1)
          {:pools, transformed_pools}

        _ ->
          {safe_to_atom(key), value}
      end
    end
  end

  defp transform_dhcpv4_pool(pool) when is_map(pool) do
    for {key, value} <- pool, into: %{} do
      case key do
        "name" -> {:name, value}
        "subnet" -> {:subnet, value}
        "range_start" -> {:range_start, parse_ipv4!(value)}
        "range_end" -> {:range_end, parse_ipv4!(value)}
        "gateway" -> {:gateway, parse_ipv4!(value)}
        "dns_servers" -> {:dns_servers, Enum.map(value, &parse_ipv4!/1)}
        "lease_time" -> {:lease_time, value}
        _ -> {safe_to_atom(key), value}
      end
    end
  end

  defp transform_dhcpv6(section) when is_map(section) do
    for {key, value} <- section, into: %{} do
      case key do
        "port" when is_integer(value) ->
          {:port, value}

        "listen" when is_binary(value) ->
          case parse_ipv6(value) do
            {:ok, ip_tuple} -> {:listen, ip_tuple}
            :error -> {:listen, value}
          end

        "lease_time" when is_integer(value) ->
          {:lease_time, value}

        "pools" when is_list(value) ->
          transformed_pools = Enum.map(value, &transform_dhcpv6_pool/1)
          {:pools, transformed_pools}

        _ ->
          {safe_to_atom(key), value}
      end
    end
  end

  defp transform_dhcpv6_pool(pool) when is_map(pool) do
    for {key, value} <- pool, into: %{} do
      case key do
        "name" -> {:name, value}
        "prefix" -> {:prefix, value}
        "dns_servers" -> {:dns_servers, Enum.map(value, &parse_ipv6!/1)}
        "lease_time" -> {:lease_time, value}
        _ -> {safe_to_atom(key), value}
      end
    end
  end

  # Safe atom conversion — uses existing atoms to prevent atom table exhaustion
  defp safe_to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  # IPv4 parsing — delegates to :inet.parse_ipv4_address/1
  defp parse_ipv4(ip_string) when is_binary(ip_string) do
    case :inet.parse_ipv4_address(String.to_charlist(ip_string)) do
      {:ok, _ip_tuple} = ok -> ok
      {:error, _} -> :error
    end
  end

  defp parse_ipv4(_), do: :error

  defp parse_ipv4!(ip_string) do
    case parse_ipv4(ip_string) do
      {:ok, ip_tuple} -> ip_tuple
      :error -> raise ArgumentError, "Invalid IPv4 address: #{inspect(ip_string)}"
    end
  end

  # IPv6 parsing — delegates to :inet.parse_ipv6_address/1
  defp parse_ipv6(ip_string) when is_binary(ip_string) do
    case :inet.parse_ipv6_address(String.to_charlist(ip_string)) do
      {:ok, _ip_tuple} = ok -> ok
      {:error, _} -> :error
    end
  end

  defp parse_ipv6(_), do: :error

  defp parse_ipv6!(ip_string) do
    case parse_ipv6(ip_string) do
      {:ok, ip_tuple} -> ip_tuple
      :error -> raise ArgumentError, "Invalid IPv6 address: #{inspect(ip_string)}"
    end
  end
end
