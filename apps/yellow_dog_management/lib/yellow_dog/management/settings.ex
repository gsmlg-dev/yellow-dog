defmodule YellowDog.Management.Settings do
  @moduledoc "Runtime bootstrap settings for the independent Management application."

  def repo do
    [
      url: System.fetch_env!("YELLOW_DOG_MANAGEMENT_DATABASE_URL"),
      pool_size: 10
    ]
  end

  def geoip_paths do
    %{
      city: optional_path("YELLOW_DOG_MANAGEMENT_GEOIP_CITY_PATH"),
      country: optional_path("YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH")
    }
  end

  def mac_database_path, do: optional_path("YELLOW_DOG_MANAGEMENT_MAC_DATABASE_PATH")

  def artifact_directory do
    System.get_env(
      "YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY",
      Path.join(System.user_home!(), ".local/share/yellow-dog-management/artifacts")
    )
    |> Path.expand()
  end

  def backup_directory do
    System.get_env(
      "YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY",
      Path.join(System.user_home!(), ".local/share/yellow-dog-management/backups")
    )
    |> Path.expand()
  end

  def geoip_source(type, date \\ Date.utc_today()) when type in [:city, :country] do
    variable =
      if type == :city,
        do: "YELLOW_DOG_MANAGEMENT_GEOIP_CITY_URL",
        else: "YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_URL"

    System.get_env(variable) ||
      "https://download.db-ip.com/free/dbip-#{type}-lite-#{Calendar.strftime(date, "%Y-%m")}.mmdb.gz"
  end

  defp optional_path(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> Path.expand(value)
    end
  end

  def listener do
    port = System.get_env("YELLOW_DOG_MANAGEMENT_PORT", "4270") |> String.to_integer()
    if port not in 1..65535, do: raise("invalid Management HTTP port")
    bind_address = System.get_env("YELLOW_DOG_MANAGEMENT_BIND_ADDRESS", "127.0.0.1")

    ip =
      case :inet.parse_address(String.to_charlist(bind_address)) do
        {:ok, address} -> address
        {:error, _reason} -> raise "invalid Management HTTP bind address"
      end

    [plug: YellowDog.Management.Web, ip: ip, port: port]
  end

  def endpoint do
    secret =
      System.get_env("YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE") ||
        Base.encode64(:crypto.strong_rand_bytes(64))

    if byte_size(secret) < 64,
      do: raise("Management secret key base must contain at least 64 bytes")

    [
      server: Application.get_env(:yellow_dog_management, :http_enabled, true),
      http: Keyword.drop(listener(), [:plug]),
      secret_key_base: secret
    ]
  end
end
