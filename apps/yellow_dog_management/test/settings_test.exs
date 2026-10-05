defmodule YellowDog.Management.SettingsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Settings

  setup do
    names = [
      "YELLOW_DOG_MANAGEMENT_BIND_ADDRESS",
      "YELLOW_DOG_MANAGEMENT_PORT",
      "YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE",
      "YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN",
      "YELLOW_DOG_MANAGEMENT_GEOIP_CITY_PATH",
      "YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH",
      "YELLOW_DOG_MANAGEMENT_MAC_DATABASE_PATH"
    ]

    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end)

    :ok
  end

  test "listener defaults to loopback port 4270 without an operator token" do
    listener = Settings.listener()
    assert listener[:ip] == {127, 0, 0, 1}
    assert listener[:port] == 4270
  end

  test "GeoIP artifact paths are independent bootstrap settings and optional" do
    assert Settings.geoip_paths() == %{city: nil, country: nil}
    System.put_env("YELLOW_DOG_MANAGEMENT_GEOIP_CITY_PATH", "data/city.mmdb")
    System.put_env("YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH", "")
    assert Settings.geoip_paths() == %{city: Path.expand("data/city.mmdb"), country: nil}
  end

  test "MAC artifact path is optional and resolves against the working directory" do
    assert Settings.mac_database_path() == nil
    System.put_env("YELLOW_DOG_MANAGEMENT_MAC_DATABASE_PATH", "data/manuf.txt")
    assert Settings.mac_database_path() == Path.expand("data/manuf.txt")
    System.put_env("YELLOW_DOG_MANAGEMENT_MAC_DATABASE_PATH", "")
    assert Settings.mac_database_path() == nil
  end

  test "listener accepts an explicit port override" do
    System.put_env("YELLOW_DOG_MANAGEMENT_PORT", "4321")
    assert Settings.listener()[:port] == 4321
  end

  test "listener can bind all IPv4 interfaces" do
    System.put_env("YELLOW_DOG_MANAGEMENT_BIND_ADDRESS", "0.0.0.0")
    assert Settings.listener()[:ip] == {0, 0, 0, 0}
  end

  test "listener rejects invalid bind addresses" do
    System.put_env("YELLOW_DOG_MANAGEMENT_BIND_ADDRESS", "not-an-ip")
    assert_raise RuntimeError, "invalid Management HTTP bind address", &Settings.listener/0
  end

  test "LiveView uses a generated session key unless a stable bootstrap key is provided" do
    assert byte_size(Settings.endpoint()[:secret_key_base]) >= 64
    key = String.duplicate("a", 64)
    System.put_env("YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE", key)
    assert Settings.endpoint()[:secret_key_base] == key
    System.put_env("YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE", "short")

    assert_raise RuntimeError, "Management secret key base must contain at least 64 bytes", fn ->
      Settings.endpoint()
    end
  end
end
