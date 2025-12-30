defmodule YellowDog.Application do
  @moduledoc """
  Main application supervisor for YellowDog with conditional service starting.

  Starts the configuration manager first, then conditionally starts protocol
  services based on the configuration settings.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Attach telemetry logger handlers before starting services
    # This enables log output for all protocol-specific telemetry events
    YellowDog.Telemetry.attach_logger_handlers()

    # Attach Abyss logger if configured
    # This enables debug logging for UDP transport operations
    if log_level = Application.get_env(:abyss, :log_level) do
      Abyss.Logger.attach_logger(log_level)
    end

    # Load TOML configuration in the application
    config = load_toml_config()

    # Log which config file was loaded and enabled services
    log_config_info(config)

    # Debug: emit telemetry for loaded config
    :telemetry.execute(
      [:yellow_dog, :config, :loaded],
      %{count: 1},
      %{source: __MODULE__, severity: :debug}
    )

    children = [
      # Configuration manager - must start first
      {YellowDog.Config, config}
    ]

    # Add protocol supervisors conditionally based on configuration
    children = children ++ get_enabled_services(config)

    # Add service heartbeat for periodic status logging
    children = children ++ [YellowDog.ServiceHeartbeat]

    # Note: YellowDog.Console and YellowDog.Telemetry have their own Application
    # modules and start separately as OTP applications (required for Phoenix dependencies)

    opts = [strategy: :one_for_one, name: YellowDog.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Starts a service supervisor dynamically.

  ## Parameters
  - `service` - Service name (:dns, :mdns, :dhcpv4, :dhcpv6)
  - `supervisor_module` - The supervisor module to start

  ## Returns
  - `{:ok, pid}` if started successfully
  - `{:error, reason}` if start failed
  """
  @spec start_service_supervisor(atom(), module()) :: {:ok, pid()} | {:error, term()}
  def start_service_supervisor(service, _supervisor_module) do
    # Get the app module for this service
    app_module = service_app_module(service)

    # Get server options from current config
    config = YellowDog.Config.get_all()
    server_options = build_server_options(config, service)

    # Build child spec
    child_spec = {app_module, server_options: server_options}

    # Start the child under the main supervisor
    case Supervisor.start_child(YellowDog.Supervisor, child_spec) do
      {:ok, pid} ->
        :telemetry.execute(
          [:yellow_dog, :service, :started],
          %{count: 1},
          %{source: __MODULE__, service: service, pid: inspect(pid), severity: :info}
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        :telemetry.execute(
          [:yellow_dog, :service, :started],
          %{count: 1},
          %{
            source: __MODULE__,
            service: service,
            pid: inspect(pid),
            already_started: true,
            severity: :info
          }
        )

        {:error, {:already_started, pid}}

      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :application, :error],
          %{count: 1},
          %{source: __MODULE__, service: service, reason: inspect(reason), severity: :error}
        )

        error
    end
  end

  @doc """
  Stops a service supervisor dynamically.

  ## Parameters
  - `service` - Service name (:dns, :mdns, :dhcpv4, :dhcpv6)
  - `supervisor_module` - The supervisor module to stop

  ## Returns
  - `:ok` if stopped successfully
  - `{:error, reason}` if stop failed
  """
  @spec stop_service_supervisor(atom(), module()) :: :ok | {:error, term()}
  def stop_service_supervisor(service, _supervisor_module) do
    app_module = service_app_module(service)

    case Supervisor.terminate_child(YellowDog.Supervisor, app_module) do
      :ok ->
        # Also delete the child spec so it can be restarted later
        Supervisor.delete_child(YellowDog.Supervisor, app_module)

        :telemetry.execute(
          [:yellow_dog, :service, :stopped],
          %{count: 1},
          %{source: __MODULE__, service: service, severity: :info}
        )

        :ok

      {:error, :not_found} ->
        :telemetry.execute(
          [:yellow_dog, :service, :stopped],
          %{count: 1},
          %{source: __MODULE__, service: service, not_found: true, severity: :debug}
        )

        {:error, :not_found}

      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :application, :error],
          %{count: 1},
          %{source: __MODULE__, service: service, reason: inspect(reason), severity: :error}
        )

        error
    end
  end

  # Maps service atom to app module
  defp service_app_module(:dns), do: YellowDog.Dns
  defp service_app_module(:mdns), do: YellowDog.Mdns
  defp service_app_module(:dhcpv4), do: YellowDog.Dhcpv4
  defp service_app_module(:dhcpv6), do: YellowDog.Dhcpv6

  # Note: config_change is not needed in the main YellowDog app
  # The console app handles its own config changes through YellowDog.Console.Application

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
                |> put_in(["dns", "port"], 53)
                |> put_in(["dhcpv4", "port"], 67)
                |> put_in(["dhcpv6", "port"], 547)
              else
                config
              end

            {:error, reason} ->
              :telemetry.execute(
                [:yellow_dog, :config, :error],
                %{count: 1},
                %{
                  source: __MODULE__,
                  reason: :parse_error,
                  config_file: config_file_path,
                  error: inspect(reason),
                  severity: :warning
                }
              )

              get_default_config()
          end

        {:error, reason} ->
          :telemetry.execute(
            [:yellow_dog, :config, :error],
            %{count: 1},
            %{
              source: __MODULE__,
              reason: :read_error,
              config_file: config_file_path,
              error: inspect(reason),
              severity: :warning
            }
          )

          get_default_config()
      end
    else
      :telemetry.execute(
        [:yellow_dog, :config, :error],
        %{count: 1},
        %{source: __MODULE__, reason: :no_config_path, severity: :warning}
      )

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
        "port" => 5353,
        "mode" => "hybrid",
        "services" => %{
          "file" => "data/mdns_services.toml",
          "format" => "toml",
          "auto_save" => true,
          "watch_file" => true,
          "load_on_start" => true
        },
        "responder" => %{
          "enabled" => true,
          "service_ttl" => 4500,
          "host_ttl" => 120,
          "enable_probing" => true,
          "enable_announcements" => true,
          "announcement_interval" => 3600
        },
        "monitor" => %{
          "enabled" => true,
          "cache_responses" => true,
          "log_queries" => true,
          "max_cache_size" => 10000,
          "cleanup_interval" => 300,
          "cache_ttl" => 120
        }
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

    is_default = config_file_path && config_file_path == default_config_path

    :telemetry.execute(
      [:yellow_dog, :config, :loaded],
      %{count: 1},
      %{
        source: __MODULE__,
        config_file: config_file_path,
        is_default: is_default,
        severity: :info
      }
    )

    # Log enabled services
    case Map.get(config, "core") do
      %{"dns" => dns, "mdns" => mdns, "dhcpv4" => dhcpv4, "dhcpv6" => dhcpv6} ->
        enabled_services =
          [{"DNS", dns}, {"mDNS", mdns}, {"DHCPv4", dhcpv4}, {"DHCPv6", dhcpv6}]
          |> Enum.filter(fn {_name, enabled} -> enabled end)
          |> Enum.map(fn {name, _enabled} -> name end)

        disabled_services =
          [{"DNS", dns}, {"mDNS", mdns}, {"DHCPv4", dhcpv4}, {"DHCPv6", dhcpv6}]
          |> Enum.filter(fn {_name, enabled} -> not enabled end)
          |> Enum.map(fn {name, _enabled} -> name end)

        :telemetry.execute(
          [:yellow_dog, :config, :validated],
          %{
            count: 1,
            enabled_count: length(enabled_services),
            disabled_count: length(disabled_services)
          },
          %{
            source: __MODULE__,
            enabled_services: Enum.join(enabled_services, ", "),
            disabled_services: Enum.join(disabled_services, ", "),
            severity: :info
          }
        )

      _ ->
        :telemetry.execute(
          [:yellow_dog, :config, :error],
          %{count: 1},
          %{source: __MODULE__, reason: :no_core_config, severity: :warning}
        )
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
        service_enabled?(config, service_name)
      end)
      |> Enum.map(fn {module, service_name} ->
        server_options = build_server_options(config, service_name)
        {module, server_options: server_options}
      end)

    # Log which services are being started
    service_names =
      services
      |> Enum.filter(fn {_module, service_name} ->
        service_enabled?(config, service_name)
      end)
      |> Enum.map(fn {_module, service_name} ->
        service_name |> to_string() |> String.upcase()
      end)

    if length(service_names) > 0 do
      :telemetry.execute(
        [:yellow_dog, :application, :start],
        %{count: length(service_names)},
        %{source: __MODULE__, services: Enum.join(service_names, ", "), severity: :info}
      )
    end

    # Log disabled services
    disabled_services =
      services
      |> Enum.filter(fn {_module, service_name} ->
        not service_enabled?(config, service_name)
      end)
      |> Enum.map(fn {_module, service_name} ->
        service_name |> to_string() |> String.upcase()
      end)

    if length(disabled_services) > 0 do
      :telemetry.execute(
        [:yellow_dog, :application, :start],
        %{count: 0, skipped: length(disabled_services)},
        %{
          source: __MODULE__,
          skipped_services: Enum.join(disabled_services, ", "),
          severity: :info
        }
      )
    end

    enabled_services
  end

  # Builds server options for a specific service from the configuration.
  defp build_server_options(config, service_name) do
    service_config = Map.get(config, to_string(service_name), %{})

    case service_name do
      :dns ->
        [
          port: Map.get(service_config, "port", 53),
          listen: convert_ip(Map.get(service_config, "listen", "0.0.0.0"))
        ]

      :mdns ->
        services_config = Map.get(service_config, "services", %{})
        responder_config = Map.get(service_config, "responder", %{})
        monitor_config = Map.get(service_config, "monitor", %{})

        [
          port: Map.get(service_config, "port", 5353),
          listen_address: convert_ip(Map.get(service_config, "listen", "0.0.0.0")),
          mode: String.to_atom(Map.get(service_config, "mode", "hybrid")),
          # Service registry options
          storage_file: Map.get(services_config, "file", "data/mdns_services.toml"),
          storage_format: String.to_atom(Map.get(services_config, "format", "toml")),
          auto_save: Map.get(services_config, "auto_save", true),
          watch_file: Map.get(services_config, "watch_file", true),
          load_on_start: Map.get(services_config, "load_on_start", true),
          # Responder options
          responder_enabled: Map.get(responder_config, "enabled", true),
          service_ttl: Map.get(responder_config, "service_ttl", 4500),
          host_ttl: Map.get(responder_config, "host_ttl", 120),
          enable_probing: Map.get(responder_config, "enable_probing", true),
          enable_announcements: Map.get(responder_config, "enable_announcements", true),
          announcement_interval: Map.get(responder_config, "announcement_interval", 3600),
          # Monitor options
          monitor_enabled: Map.get(monitor_config, "enabled", true),
          cache_responses: Map.get(monitor_config, "cache_responses", true),
          log_queries: Map.get(monitor_config, "log_queries", true),
          max_cache_size: Map.get(monitor_config, "max_cache_size", 10000),
          cleanup_interval: Map.get(monitor_config, "cleanup_interval", 300),
          cache_ttl: Map.get(monitor_config, "cache_ttl", 120)
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
        # fallback
        {0, 0, 0, 0}
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
  defp service_enabled?(config, service_name) do
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
        lease_time: Map.get(pool_map, "lease_time", 86_400),
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
