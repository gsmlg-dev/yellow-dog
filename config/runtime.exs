import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/yellow_dog_console start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :yellow_dog_console, YellowDog.Console.Endpoint, server: true
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4270")

  config :yellow_dog_console, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :yellow_dog_console, YellowDog.Console.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # Configure basic authentication for the web console
  # CONSOLE_AUTH_ENABLED defaults to true in production
  # Set CONSOLE_PASSWORD to enable authentication (required for auth to work)
  auth_enabled = System.get_env("CONSOLE_AUTH_ENABLED", "true") != "false"

  config :yellow_dog_console, YellowDog.Console.Plugs.BasicAuth,
    enabled: auth_enabled,
    username: System.get_env("CONSOLE_USERNAME", "admin"),
    password: System.get_env("CONSOLE_PASSWORD"),
    realm: System.get_env("CONSOLE_REALM", "YellowDog Console")
end

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

# Helper function to parse CLI argument value
get_cli_arg = fn arg_name ->
  args = System.argv()

  case Enum.find_index(args, &(&1 == arg_name)) do
    nil ->
      nil

    index ->
      value = Enum.at(args, index + 1)
      if value && not String.starts_with?(value, "-"), do: value
  end
end

# Default configuration fallback.
# In dev, use the same config file edited by the console settings page.
default_config_path =
  if config_env() == :dev do
    Path.expand("../priv/yellowdogdns_default_config.toml", __DIR__)
  else
    Path.expand("../apps/yellow_dog/priv/yellowdogdns_default_config.toml", __DIR__)
  end

# Determine which config file to use (CLI > ENV > default)
# Priority: --config CLI arg > YELLOW_DOG_CONFIG env > default
config_path =
  get_cli_arg.("--config") ||
    System.get_env("YELLOW_DOG_CONFIG") ||
    default_config_path

config_to_load =
  if File.exists?(config_path) do
    config_path
  else
    default_config_path
  end

# Store config file path in application config (the actual TOML reading will be done in the application)
config :yellow_dog, :config_file_path, config_to_load

# Determine data directory (CLI > ENV > default)
# Priority: --data-dir CLI arg > YELLOW_DOG_DATA_DIR env > default from config
data_dir =
  get_cli_arg.("--data-dir") ||
    System.get_env("YELLOW_DOG_DATA_DIR")

# Store data directory in application config (nil means use config file value or default)
config :yellow_dog, :data_dir, data_dir

normalize_cluster_env = fn
  nil -> nil
  value -> value |> String.trim() |> String.downcase()
end

cluster_env_enabled? = fn value ->
  case normalize_cluster_env.(value) do
    enabled when enabled in ["1", "true", "yes", "on"] -> true
    _ -> false
  end
end

cluster_env_disabled? = fn value ->
  case normalize_cluster_env.(value) do
    disabled when disabled in ["0", "false", "no", "off"] -> true
    _ -> false
  end
end

cluster_nodes_env = System.get_env("CONCORD_CLUSTER_NODES")

cluster_nodes =
  case cluster_nodes_env do
    nil -> []
    nodes -> String.split(nodes, ",", trim: true)
  end
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

cluster_enabled_env = System.get_env("CONCORD_CLUSTERING")

configured_topologies =
  Application.get_env(:concord, :topologies) ||
    Application.get_env(:libcluster, :topologies) ||
    []

cluster_enabled? =
  cond do
    cluster_env_disabled?.(cluster_enabled_env) -> false
    cluster_env_enabled?.(cluster_enabled_env) -> true
    true -> cluster_nodes != [] or configured_topologies != []
  end

if cluster_enabled? do
  cluster_topology =
    cond do
      cluster_nodes != [] ->
        [
          concord_epmd: [
            strategy: Cluster.Strategy.Epmd,
            config: [hosts: Enum.map(cluster_nodes, &String.to_atom/1)]
          ]
        ]

      configured_topologies != [] ->
        configured_topologies

      true ->
        [
          concord_gossip: [
            strategy: Cluster.Strategy.Gossip
          ]
        ]
    end

  config :concord,
    clustering: true,
    topologies: cluster_topology
else
  config :concord,
    clustering: false,
    topologies: []
end

# Disable NetMan on macOS — it relies on Linux kernel interfaces (netlink, etc.)
# that are not available on macOS.
if :os.type() == {:unix, :darwin} do
  config :yellow_dog, :netman_enabled, false
end

# NetMan configuration from environment
if profile_dir = System.get_env("YELLOW_DOG_NETMAN_PROFILE_DIR") do
  config :yellow_dog_netman, :profile_dir, profile_dir
end

if socket_path = System.get_env("YELLOW_DOG_NETMAN_SOCKET") do
  config :yellow_dog_netman, :socket_path, socket_path
end

# Netman console WebSocket client
if console_url = System.get_env("YELLOW_DOG_NETMAN_CONSOLE_URL") do
  console_config =
    Application.get_env(:yellow_dog_netman, :console, [])
    |> Keyword.merge(
      enabled: true,
      url: console_url,
      token: System.get_env("YELLOW_DOG_NETMAN_CONSOLE_TOKEN", ""),
      node_id: System.get_env("YELLOW_DOG_NETMAN_NODE_ID"),
      hostname: System.get_env("YELLOW_DOG_NETMAN_HOSTNAME")
    )
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)

  config :yellow_dog_netman, :console, console_config
end

if System.get_env("MIX_BUN_PATH") do
  executable = System.get_env("MIX_BUN_PATH")

  bun_version =
    case System.cmd(executable, ["--version"]) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end

  config :bun,
    path: executable,
    version: bun_version
end

if System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: System.get_env("MIX_TAILWIND_PATH")
end
