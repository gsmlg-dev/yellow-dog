import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# Handle LOG_LEVEL environment variable
if config_env() == :prod do
  case System.fetch_env("LOG_LEVEL") do
    {:ok, level} ->
      config :logger, :console, level: String.to_atom(level)

    _ ->
      nil
  end
end

# Helper function to get config path from command line arguments
get_config_path = fn ->
  # Parse command line arguments for --config flag
  case System.argv() do
    args ->
      args
      |> Enum.with_index()
      |> Enum.find(fn {arg, _index} -> arg == "--config" end)
      |> case do
        nil ->
          nil

        {_config_arg, index} ->
          config_file = Enum.at(args, index + 1)

          if config_file && not String.starts_with?(config_file, "-") do
            config_file
          else
            nil
          end
      end
  end
end

# Default configuration fallback
default_config = %{
  "core" => %{
    "dns" => true,
    "mdns" => true,
    "dhcpv4" => true,
    "dhcpv6" => true
  },
  "dns" => %{
    "listen" => "0.0.0.0",
    "port" => 53
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

# Load TOML configuration
config_path = get_config_path.()

default_config_path =
  Path.join([Application.app_dir(:yellow_dog), "priv", "yellowdogdns_default_config.toml"])

# Try to load custom config first, then fall back to default
config_to_load =
  if config_path && File.exists?(config_path) do
    config_path
  else
    default_config_path
  end

# Simple TOML loading
config_to_use =
  case File.read(config_to_load) do
    {:ok, content} ->
      case Toml.decode(content) do
        {:ok, config} ->
          config

        {:error, _reason} ->
          IO.puts("Warning: Failed to parse TOML from #{config_to_load}, using defaults")
          default_config
      end

    {:error, _reason} ->
      IO.puts("Warning: Failed to read config file #{config_to_load}, using defaults")
      default_config
  end

# Store the loaded configuration in application config
config :yellow_dog, :toml_config, config_to_use

# Log which config file was loaded and enabled services
if config_path && File.exists?(config_path) do
  IO.puts("Loaded custom configuration from: #{config_path}")
else
  IO.puts("Loaded default configuration from: #{default_config_path}")
end

# Log enabled services
case Map.get(config_to_use, "core") do
  %{"dns" => dns, "mdns" => mdns, "dhcpv4" => dhcpv4, "dhcpv6" => dhcpv6} ->
    enabled_services =
      [{"DNS", dns}, {"mDNS", mdns}, {"DHCPv4", dhcpv4}, {"DHCPv6", dhcpv6}]
      |> Enum.filter(fn {_name, enabled} -> enabled end)
      |> Enum.map(fn {name, _enabled} -> name end)

    IO.puts("Enabled services: #{Enum.join(enabled_services, ", ")}")

    disabled_services =
      [{"DNS", dns}, {"mDNS", mdns}, {"DHCPv4", dhcpv4}, {"DHCPv6", dhcpv6}]
      |> Enum.filter(fn {_name, enabled} -> not enabled end)
      |> Enum.map(fn {name, _enabled} -> name end)

    if length(disabled_services) > 0 do
      IO.puts("Disabled services: #{Enum.join(disabled_services, ", ")}")
    end

  _ ->
    IO.puts("Warning: No [core] configuration found, enabling all services")
end
