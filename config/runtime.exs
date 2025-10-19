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
default_config_path = Path.expand("../apps/yellow_dog/priv/yellowdogdns_default_config.toml", __DIR__)

# Determine which config file to use
config_path = get_config_path.()
config_to_load =
  if config_path && File.exists?(config_path) do
    config_path
  else
    default_config_path
  end

# Store config file path in application config (the actual TOML reading will be done in the application)
config :yellow_dog, :config_file_path, config_to_load
