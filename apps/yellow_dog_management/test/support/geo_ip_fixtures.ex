defmodule YellowDog.Management.GeoIPFixtures do
  @fixture Path.expand("../fixtures/geoip/GeoIP2-City-Test.mmdb.base64", __DIR__)

  def binary do
    @fixture
    |> File.read!()
    |> String.replace(~r/\s/, "")
    |> Base.decode64!()
  end

  def write!(directory, filename \\ "city.mmdb") do
    path = Path.join(directory, filename)
    File.write!(path, binary())
    path
  end

  def wait_loaded(server, attempts \\ 100)

  def wait_loaded(_server, 0), do: raise("GeoIP fixture did not finish loading")

  def wait_loaded(server, attempts) do
    entries = YellowDog.Management.GeoIP.info(server)

    if Enum.any?(entries, &(&1.status == :loading)) do
      Process.sleep(10)
      wait_loaded(server, attempts - 1)
    else
      entries
    end
  end
end
