defmodule GeoIpDbTest do
  use ExUnit.Case, async: false

  alias GeoIpDb.Database

  setup do
    # Stop any existing database server
    case Process.whereis(Database) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    # Clean up any existing ETS table
    if :ets.whereis(:geo_ip_db_databases) != :undefined do
      :ets.delete(:geo_ip_db_databases)
    end

    # Start a fresh database server
    {:ok, pid} = Database.start_link([])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    :ok
  end

  describe "lookup/2" do
    @tag :requires_database
    test "returns geo info for valid IPv4 address" do
      # Google's DNS - well-known public IP
      assert {:ok, info} = GeoIpDb.lookup("8.8.8.8")
      assert is_map(info)
      assert Map.has_key?(info, :country)
      assert Map.has_key?(info, :country_code)
    end

    @tag :requires_database
    test "returns geo info for IPv4 tuple" do
      assert {:ok, info} = GeoIpDb.lookup({8, 8, 8, 8})
      assert is_map(info)
    end

    @tag :requires_database
    test "returns geo info for IPv6 address" do
      # Google's IPv6 DNS
      assert {:ok, info} = GeoIpDb.lookup("2001:4860:4860::8888")
      assert is_map(info)
    end

    test "returns error for invalid IP" do
      assert {:error, {:invalid_ip, _}} = GeoIpDb.lookup(:not_an_ip)
    end

    test "returns error for malformed IP string" do
      assert {:error, :einval} = GeoIpDb.lookup("not.a.valid.ip")
    end
  end

  describe "country/2" do
    @tag :requires_database
    test "returns country name for valid IP" do
      assert {:ok, country} = GeoIpDb.country("8.8.8.8")
      assert is_binary(country) or is_nil(country)
    end
  end

  describe "country_code/2" do
    @tag :requires_database
    test "returns ISO country code for valid IP" do
      assert {:ok, code} = GeoIpDb.country_code("8.8.8.8")
      # Country code should be 2-letter ISO code or nil
      assert is_nil(code) or (is_binary(code) and byte_size(code) == 2)
    end
  end

  describe "city/2" do
    @tag :requires_database
    test "returns city name for valid IP" do
      assert {:ok, city} = GeoIpDb.city("8.8.8.8")
      assert is_binary(city) or is_nil(city)
    end
  end

  describe "coordinates/2" do
    @tag :requires_database
    test "returns lat/long tuple for valid IP" do
      case GeoIpDb.coordinates("8.8.8.8") do
        {:ok, {lat, lon}} ->
          assert is_float(lat) or is_integer(lat)
          assert is_float(lon) or is_integer(lon)
          assert lat >= -90 and lat <= 90
          assert lon >= -180 and lon <= 180

        {:ok, nil} ->
          # Some IPs may not have coordinates
          :ok
      end
    end
  end

  describe "list_databases/0" do
    @tag :requires_database
    test "returns list of loaded database names" do
      databases = GeoIpDb.list_databases()
      assert is_list(databases)
    end
  end

  describe "database_info/1" do
    @tag :requires_database
    test "returns metadata for loaded database" do
      case GeoIpDb.database_info(:city) do
        {:ok, info} ->
          assert Map.has_key?(info, :database_type)
          assert Map.has_key?(info, :build_epoch)
          assert %DateTime{} = info.build_epoch

        {:error, {:database_not_loaded, :city}} ->
          # Database not loaded, skip
          :ok
      end
    end

    test "returns error for unknown database" do
      assert {:error, {:database_not_loaded, :nonexistent}} =
               GeoIpDb.database_info(:nonexistent)
    end
  end
end
