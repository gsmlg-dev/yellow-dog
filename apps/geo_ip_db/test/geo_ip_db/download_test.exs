defmodule GeoIpDb.DownloadTest do
  use ExUnit.Case, async: true

  alias GeoIpDb.Download

  @moduletag :tmp_dir

  test "uses a provided fetcher instead of the network", %{tmp_dir: tmp_dir} do
    parent = self()

    fetcher = fn url ->
      send(parent, {:fetcher_used, url})
      %HTTP.Response{ok: true, status: 200, body: :zlib.gzip("not-mmdb")}
    end

    assert {:ok, path} = Download.download(:city, target_dir: tmp_dir, fetcher: fetcher)
    assert_receive {:fetcher_used, url}
    assert url =~ "dbip-city-lite"
    assert File.read!(path) == "not-mmdb"
  end
end
