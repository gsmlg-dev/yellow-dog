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

  test "reads streamed response bodies before decompression", %{tmp_dir: tmp_dir} do
    target_path = Download.target_path(:city, target_dir: tmp_dir)
    File.write!(target_path, "old-mmdb")

    compressed = :zlib.gzip("not-mmdb")

    fetcher = fn _url ->
      stream = streamed_body(compressed)

      %HTTP.Response{ok: true, status: 200, body: nil, stream: stream}
    end

    assert {:error, {:invalid_database, _reason}} =
             Download.download(:city, target_dir: tmp_dir, fetcher: fetcher)

    assert File.read!(target_path) == "old-mmdb"
    assert Path.wildcard(Path.join(tmp_dir, "*.tmp")) == []
  end

  defp streamed_body(body) do
    spawn_link(fn ->
      receive do
        {:read_chunk, reader} ->
          send(reader, {:stream_chunk, self(), body})
          send(reader, {:stream_end, self()})

        {:read_chunk, reader, :ack} ->
          ref = make_ref()
          send(reader, {:stream_chunk, self(), body, ref})

          receive do
            {:stream_chunk_ack, ^ref} -> :ok
          end

          send(reader, {:stream_end, self()})
      end
    end)
  end
end
