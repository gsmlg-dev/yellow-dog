defmodule GeoIpDb.DownloadTest do
  use ExUnit.Case, async: true

  alias GeoIpDb.Download

  @moduletag :tmp_dir

  test "uses a provided fetcher and preserves existing files when validation fails", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    target_path = Download.target_path(:city, target_dir: tmp_dir)
    File.write!(target_path, "old-mmdb")

    fetcher = fn url ->
      send(parent, {:fetcher_used, url})
      %HTTP.Response{ok: true, status: 200, body: :zlib.gzip("not-mmdb")}
    end

    assert {:error, {:invalid_database, _reason}} =
             Download.download(:city, target_dir: tmp_dir, fetcher: fetcher)

    assert_receive {:fetcher_used, url}
    assert url =~ "dbip-city-lite"
    assert File.read!(target_path) == "old-mmdb"
    assert Path.wildcard(Path.join(tmp_dir, "*.tmp")) == []
  end
end
