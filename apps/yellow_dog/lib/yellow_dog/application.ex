defmodule YellowDog.Application do
  @moduledoc """
  Main application supervisor for YellowDog with conditional service starting.

  Starts the configuration manager first, then conditionally starts protocol
  services based on the configuration settings.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Load TOML configuration in the application
    config = load_toml_config()

    # Log which config file was loaded and enabled services
    log_config_info(config)

    # Debug: print the actual config being loaded
    Logger.debug("Loaded config: #{inspect(config)}")

    children = [
      # Configuration manager - must start first
      {YellowDog.Config, config}
    ]

    # Add protocol supervisors conditionally based on configuration
    children = children ++ get_enabled_services(config)

    opts = [strategy: :one_for_one, name: YellowDog.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Loads TOML configuration from the file path specified in runtime.exs
  defp load_toml_config do
    # Get config file path from application config (set in runtime.exs)
    config_file_path = Application.get_env(:yellow_dog, :config_file_path)

    if config_file_path do
      # Load and parse TOML configuration
      case File.read(config_file_path) do
        {:ok, content} ->
          case Toml.decode(content) do
            {:ok, config} ->
              # Adjust configuration for test environment
              if Mix.env() == :test do
                config
                |> put_in(["core", "dns"], false)
                |> put_in(["core", "mdns"], false)
                |> put_in(["core", "dhcpv6"], false)
                |> put_in(["dns", "port"], 5353)
                |> put_in(["dhcpv4", "port"], 6767)
                |> put_in(["dhcpv6", "port"], 5667)
              else
                config
              end

            {:error, reason} ->
              Logger.warning("Failed to parse TOML from #{config_file_path}: #{inspect(reason)}, using defaults")
              get_default_config()
          end

        {:error, reason} ->
          Logger.warning("Failed to read config file #{config_file_path}: #{inspect(reason)}, using defaults")
          get_default_config()
      end
    else
      Logger.warning("No config file path specified, using defaults")
      get_default_config()
    end
  end

  # Gets the default configuration
  defp get_default_config do
    %{
      "core" => %{
        "dns" => Mix.env() != :test,
        "mdns" => true,
        "dhcpv4" => true,
        "dhcpv6" => true
      },
      "dns" => %{
        "listen" => "0.0.0.0",
        "port" => 53,
        "zones" => %{}
      },
      "mdns" => %{
        "listen" => "0.0.0.0",
        "port" => 5353
      },
      "dhcpv4" => %{
        "listen" => "0.0.0.0",
        "port" => 67
      },
      "dhcpv6" => %{
        "listen" => "::",
        "port" => 547
      }
    }
  end

  # Logs configuration information
  defp log_config_info(config) do
    config_file_path = Application.get_env(:yellow_dog, :config_file_path)
    default_config_path = Path.expand("../priv/yellowdogdns_default_config.toml", __DIR__)

    if config_file_path && config_file_path == default_config_path do
      Logger.info("Loaded default configuration from: #{config_file_path}")
    else
      Logger.info("Loaded custom configuration from: #{config_file_path}")
    end

    # Log enabled services
    case Map.get(config, "core") do
      %{"dns" => dns, "mdns" => mdns, "dhcpv4" => dhcpv4, "dhcpv6" => dhcpv6} ->
        enabled_services =
          [{"DNS", dns}, {"mDNS", mdns}, {"DHCPv4", dhcpv4}, {"DHCPv6", dhcpv6}]
          |> Enum.filter(fn {_name, enabled} -> enabled end)
          |> Enum.map(fn {name, _enabled} -> name end)

        Logger.info("Enabled services: #{Enum.join(enabled_services, ", ")}")

        disabled_services =
          [{"DNS", dns}, {"mDNS", mdns}, {"DHCPv4", dhcpv4}, {"DHCPv6", dhcpv6}]
          |> Enum.filter(fn {_name, enabled} -> not enabled end)
          |> Enum.map(fn {name, _enabled} -> name end)

        if length(disabled_services) > 0 do
          Logger.info("Disabled services: #{Enum.join(disabled_services, ", ")}")
        end

      _ ->
        Logger.warning("No [core] configuration found, enabling all services")
    end
  end

  # Gets the list of enabled service supervisors based on configuration.
  defp get_enabled_services(config) do
    services = [
      {YellowDog.Dns, :dns},
      {YellowDog.Mdns, :mdns},
      {YellowDog.Dhcpv4, :dhcpv4},
      {YellowDog.Dhcpv6, :dhcpv6}
    ]

    # Filter services based on configuration and pass server options
    enabled_services =
      services
      |> Enum.filter(fn {_module, service_name} ->
        is_service_enabled?(config, service_name)
      end)
      |> Enum.map(fn {module, service_name} ->
        server_options = build_server_options(config, service_name)
        {module, server_options: server_options}
      end)

    # Log which services are being started
    service_names =
      services
      |> Enum.filter(fn {_module, service_name} ->
        is_service_enabled?(config, service_name)
      end)
      |> Enum.map(fn {_module, service_name} ->
        service_name |> to_string() |> String.upcase()
      end)

    if length(service_names) > 0 do
      Logger.info("Starting services: #{Enum.join(service_names, ", ")}")
    end

    # Log disabled services
    disabled_services =
      services
      |> Enum.filter(fn {_module, service_name} ->
        not is_service_enabled?(config, service_name)
      end)
      |> Enum.map(fn {_module, service_name} ->
        service_name |> to_string() |> String.upcase()
      end)

    if length(disabled_services) > 0 do
      Logger.info("Skipping disabled services: #{Enum.join(disabled_services, ", ")}")
    end

    enabled_services
  end

  # Builds server options for a specific service from the configuration.
  defp build_server_options(config, service_name) do
    service_config = Map.get(config, to_string(service_name), %{})

    case service_name do
      :dns ->
        [
          port: Map.get(service_config, "port", if(Mix.env() == :test, do: 5353, else: 53)),
          listen: convert_ip(Map.get(service_config, "listen", "0.0.0.0"))
        ]

      :mdns ->
        [
          port: Map.get(service_config, "port", 5353),
          listen_address: convert_ip(Map.get(service_config, "listen", "0.0.0.0"))
        ]

      :dhcpv4 ->
        pools = parse_dhcpv4_pools(service_config)
        static_reservations = Map.get(service_config, "static_reservations", %{})

        [
          port: Map.get(service_config, "port", 67),
          listen: convert_ip(Map.get(service_config, "listen", "0.0.0.0")),
          pools: pools,
          static_reservations: static_reservations
        ]

      :dhcpv6 ->
        pools = parse_dhcpv6_pools(service_config)
        static_reservations = Map.get(service_config, "static_reservations", %{})

        [
          port: Map.get(service_config, "port", 547),
          listen: convert_ipv6(Map.get(service_config, "listen", "::")),
          pools: pools,
          static_reservations: static_reservations
        ]
    end
  end

  # Converts IP address string to tuple format for mDNS
  defp convert_ip(ip_string) when is_binary(ip_string) do
    case String.split(ip_string, ".") do
      [a, b, c, d] when length([a, b, c, d]) == 4 ->
        {String.to_integer(a), String.to_integer(b), String.to_integer(c), String.to_integer(d)}
      _ ->
        {0, 0, 0, 0}  # fallback
    end
  end

  defp convert_ip(ip_tuple) when is_tuple(ip_tuple), do: ip_tuple
  defp convert_ip(_), do: {0, 0, 0, 0}

  # Converts IPv6 address string to tuple format for DHCPv6
  defp convert_ipv6("::"), do: {0, 0, 0, 0, 0, 0, 0, 0}
  defp convert_ipv6(ip_string) when is_binary(ip_string) do
    case :inet.parse_ipv6_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, _} -> {0, 0, 0, 0, 0, 0, 0, 0}
    end
  end
  defp convert_ipv6(ip_tuple) when is_tuple(ip_tuple), do: ip_tuple
  defp convert_ipv6(_), do: {0, 0, 0, 0, 0, 0, 0, 0}

  # Checks if a service is enabled in the configuration.
  defp is_service_enabled?(config, service_name) do
    case Map.get(config, "core") do
      %{"dns" => dns, "mdns" => mdns, "dhcpv4" => dhcpv4, "dhcpv6" => dhcpv6} ->
        case service_name do
          :dns -> dns
          :mdns -> mdns
          :dhcpv4 -> dhcpv4
          :dhcpv6 -> dhcpv6
        end

      core_config when is_map(core_config) ->
        Map.get(core_config, to_string(service_name), true)

      _ ->
        # Default to enabled if no configuration is found
        true
    end
  end

  # Parses DHCPv4 pool configuration from TOML
  defp parse_dhcpv4_pools(service_config) do
    pools = Map.get(service_config, "pools", [])

    Enum.map(pools, fn pool_map ->
      %{
        name: Map.get(pool_map, "name", "default"),
        range_start: parse_ip_or_tuple(Map.get(pool_map, "range_start", "192.168.1.100")),
        range_end: parse_ip_or_tuple(Map.get(pool_map, "range_end", "192.168.1.200")),
        subnet_mask: parse_ip_or_tuple(Map.get(pool_map, "subnet_mask", "255.255.255.0")),
        gateway: parse_ip_or_tuple(Map.get(pool_map, "gateway", "192.168.1.1")),
        dns_servers: parse_dns_servers(Map.get(pool_map, "dns_servers", ["192.168.1.1"])),
        domain_name: Map.get(pool_map, "domain_name", "local"),
        lease_time: Map.get(pool_map, "lease_time", 86400),
        static_reservations: Map.get(pool_map, "static_reservations", %{})
      }
    end)
  end

  # Parses IP address from string or tuple
  defp parse_ip_or_tuple(ip) when is_tuple(ip), do: ip
  defp parse_ip_or_tuple(ip) when is_binary(ip), do: convert_ip(ip)
  defp parse_ip_or_tuple(_), do: {0, 0, 0, 0}

  # Parses DNS servers list
  defp parse_dns_servers(servers) when is_list(servers) do
    Enum.map(servers, &parse_ip_or_tuple/1)
  end
  defp parse_dns_servers(_), do: []

  # Parses DHCPv6 pool configuration from TOML
  defp parse_dhcpv6_pools(service_config) do
    pools = Map.get(service_config, "pools", [])

    Enum.map(pools, fn pool_map ->
      %{
        name: Map.get(pool_map, "name", "default"),
        range_start: parse_ipv6_or_tuple(Map.get(pool_map, "range_start", "fd00::100")),
        range_end: parse_ipv6_or_tuple(Map.get(pool_map, "range_end", "fd00::200")),
        prefix_length: Map.get(pool_map, "prefix_length", 64),
        dns_servers: parse_ipv6_dns_servers(Map.get(pool_map, "dns_servers", ["fd00::1"])),
        domain_name: Map.get(pool_map, "domain_name", "local"),
        preferred_lifetime: Map.get(pool_map, "preferred_lifetime", 3600),
        valid_lifetime: Map.get(pool_map, "valid_lifetime", 7200),
        static_reservations: Map.get(pool_map, "static_reservations", %{})
      }
    end)
  end

  # Parses IPv6 address from string or tuple
  defp parse_ipv6_or_tuple(ip) when is_tuple(ip) and tuple_size(ip) == 8, do: ip
  defp parse_ipv6_or_tuple(ip) when is_binary(ip), do: convert_ipv6(ip)
  defp parse_ipv6_or_tuple(_), do: {0, 0, 0, 0, 0, 0, 0, 0}

  # Parses IPv6 DNS servers list
  defp parse_ipv6_dns_servers(servers) when is_list(servers) do
    Enum.map(servers, &parse_ipv6_or_tuple/1)
  end
  defp parse_ipv6_dns_servers(_), do: []
end
