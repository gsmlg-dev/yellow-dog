defmodule YellowDog.Management.GeoIPTest do
  use ExUnit.Case, async: true

  alias YellowDog.Management.{GeoIP, GeoIPFixtures}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "management-geoip-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "unconfigured startup exposes both fixed slots and never requires a database" do
    server = start_database(%{})
    assert [%{name: :city}, %{name: :country}] = entries = GeoIP.info(server)
    assert Enum.all?(entries, &(&1.status == :unconfigured && !&1.loaded && !&1.configured))
    assert {:error, :unconfigured} = GeoIP.lookup("81.2.69.160", :city, server)
    assert {:error, :unconfigured} = GeoIP.reload(:country, server)
    assert :ok = GeoIP.unload(:country, server)
  end

  test "real decoder returns every original lookup field and string-key metadata", %{
    directory: directory
  } do
    path = GeoIPFixtures.write!(directory)
    server = start_database(%{city: path})
    [city, country] = GeoIPFixtures.wait_loaded(server)
    assert city.loaded && city.configured
    assert city.status == :loaded
    assert city.path == path
    assert city.file_size == 22_569
    assert is_integer(city.modified_at)
    assert %DateTime{} = city.loaded_at
    assert city.metadata.database_type == "GeoIP2-City"
    assert city.metadata.description["en"] =~ "fake GeoIP2 data"
    assert city.metadata.ip_version == 6
    assert city.metadata.record_size == 28
    assert city.metadata.node_count == 1547
    assert city.metadata.languages == ["en", "zh"]
    refute Map.has_key?(city, :database)
    refute Map.has_key?(city, :loader)
    refute country.loaded

    assert {:ok,
            %{
              country: "United States",
              country_code: "US",
              city: "Milton",
              subdivision: "Washington",
              continent: "North America",
              continent_code: "NA",
              timezone: "America/Los_Angeles",
              postal_code: "98354",
              latitude: 47.2513,
              longitude: -122.3149
            }} = GeoIP.lookup("216.160.83.56", :city, server)

    assert {:ok, %{city: "London", country_code: "GB", subdivision: "England"}} =
             GeoIP.lookup(" 81.2.69.160 ", :city, server)

    assert {:ok, %{country: "Japan", country_code: "JP", timezone: "Asia/Tokyo", city: nil}} =
             GeoIP.lookup("2001:218::", :city, server)
  end

  test "country slot uses its configured actual MMDB and unload/reload preserves the path", %{
    directory: directory
  } do
    path = GeoIPFixtures.write!(directory)
    server = start_database(%{city: path, country: path})
    GeoIPFixtures.wait_loaded(server)
    assert {:ok, %{country_code: "GB"}} = GeoIP.lookup("81.2.69.160", :country, server)
    assert :ok = GeoIP.unload(:country, server)
    assert {:error, :not_loaded} = GeoIP.lookup("81.2.69.160", :country, server)
    assert {:ok, %{city: "London"}} = GeoIP.lookup("81.2.69.160", :city, server)

    assert %{status: :unloaded, path: ^path, metadata: %{}, loaded: false} =
             Enum.at(GeoIP.info(server), 1)

    assert :ok = GeoIP.reload(:country, server)
    assert {:ok, %{country_code: "GB"}} = GeoIP.lookup("81.2.69.160", :country, server)
  end

  test "invalid and absent addresses have distinct non-crashing outcomes", %{directory: directory} do
    server = start_database(%{city: GeoIPFixtures.write!(directory)})
    GeoIPFixtures.wait_loaded(server)

    for address <- [
          "",
          "999.1.1.1",
          "example.com",
          "127.1",
          "2001:::218",
          String.duplicate("a", 65),
          nil,
          <<255>>
        ] do
      assert {:error, :invalid_ip} = GeoIP.lookup(address, :city, server)
    end

    assert {:error, :not_found} = GeoIP.lookup("192.0.2.1", :city, server)
    assert Process.alive?(server)
  end

  test "invalid, truncated, missing and oversized reloads retain the last valid snapshot", %{
    directory: directory
  } do
    path = GeoIPFixtures.write!(directory)
    server = start_database(%{city: path})
    [original | _entries] = GeoIPFixtures.wait_loaded(server)

    for contents <- ["not a database", binary_part(GeoIPFixtures.binary(), 0, 100), <<>>] do
      File.write!(path, contents)
      assert {:error, _reason} = GeoIP.reload(:city, server)
      assert_snapshot(server, original)
    end

    File.rm!(path)
    assert {:error, :enoent} = GeoIP.reload(:city, server)
    assert_snapshot(server, original)

    File.open!(path, [:write, :binary], fn file ->
      {:ok, _position} = :file.position(file, 256 * 1024 * 1024)
      :ok = :file.write(file, <<0>>)
    end)

    assert {:error, :too_large} = GeoIP.reload(:city, server)
    assert_snapshot(server, original)
    GeoIPFixtures.write!(directory)
    assert :ok = GeoIP.reload(:city, server)
    assert [%{status: :loaded, last_error: nil} | _entries] = GeoIP.info(server)
  end

  test "bad configured files cannot terminate the backend", %{directory: directory} do
    server = start_database(%{city: directory, country: Path.join(directory, "missing.mmdb")})
    [city, country] = GeoIPFixtures.wait_loaded(server)
    assert city.last_error == :not_regular_file
    assert country.last_error == :enoent
    assert city.status == :error && !city.loaded
    assert {:error, :not_loaded} = GeoIP.lookup("81.2.69.160", :city, server)
    assert Process.alive?(server)
  end

  test "only fixed enum slots are accepted and absent servers are meaningful errors" do
    server = start_database(%{unknown: "/etc/passwd", city: ""})

    for type <- [:unknown, "city", "country", %{"path" => "/etc/passwd"}, nil] do
      assert {:error, :invalid_type} = GeoIP.reload(type, server)
      assert {:error, :invalid_type} = GeoIP.unload(type, server)
      assert {:error, :invalid_type} = GeoIP.lookup("81.2.69.160", type, server)
    end

    send(server, {:load_result, :unknown, make_ref(), :invalid})
    send(server, {:load_timeout, :unknown, make_ref()})
    assert [%{path: nil}, %{path: nil}] = GeoIP.info(server)
    assert {:error, :unavailable} = GeoIP.info(:nonexistent_management_geoip_test)

    assert {:error, :unavailable} =
             GeoIP.lookup("81.2.69.160", :city, :nonexistent_management_geoip_test)
  end

  defp start_database(paths), do: start_supervised!({GeoIP, name: nil, paths: paths})

  defp assert_snapshot(server, original) do
    assert [city | _entries] = GeoIP.info(server)
    assert city.status == :error && city.loaded
    assert city.metadata == original.metadata
    assert city.loaded_at == original.loaded_at
    assert city.file_size == original.file_size
    assert {:ok, %{city: "London"}} = GeoIP.lookup("81.2.69.160", :city, server)
  end
end
