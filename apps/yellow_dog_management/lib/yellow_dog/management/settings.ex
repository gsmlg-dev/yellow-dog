defmodule YellowDog.Management.Settings do
  @moduledoc "Runtime bootstrap settings for the independent Management application."

  def repo do
    [
      url: System.fetch_env!("YELLOW_DOG_MANAGEMENT_DATABASE_URL"),
      pool_size: 10
    ]
  end

  def token do
    case System.get_env("YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN") do
      token when is_binary(token) and byte_size(token) >= 32 -> token
      _ -> raise "YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN must contain at least 32 bytes"
    end
  end

  def listener do
    token()
    port = System.get_env("YELLOW_DOG_MANAGEMENT_PORT", "4280") |> String.to_integer()
    if port not in 1..65535, do: raise("invalid Management HTTP port")
    # An authenticated TLS reverse proxy may expose this loopback listener.
    [plug: YellowDog.Management.Web, ip: {127, 0, 0, 1}, port: port]
  end
end
