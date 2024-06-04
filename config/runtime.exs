import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

if config_env() == :prod do
  if System.get_env("YD_PORT") do
    port = System.get_env("YD_PORT") |> String.to_integer()
    config :yellow_dog, YellowDog.Server, port: port
  end

  if System.get_env("YD_FORWARDER") do
    ip = System.get_env("YD_FORWARDER")

    port =
      if System.get_env("YD_FORWARDER_PORT") do
        System.get_env("YD_FORWARDER_PORT") |> String.to_integer()
      else
        53
      end

    config :yellow_dog, YellowDog.Server, default_forwarder: {ip, port}
  end
end
