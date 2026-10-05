defmodule YellowDog.Management.GeoIPDownloadTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.GeoIPDownload
  alias YellowDog.Management.GeoIPDownloadFixture
  alias YellowDog.Management.GeoIPFixtures

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "geo-ip-download-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, database: GeoIPFixtures.binary()}
  end

  test "streams, validates and durably publishes an immutable City artifact", context do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database))
    assert {:ok, artifact} = GeoIPDownload.fetch(:city, context.directory, url: url)
    digest = Base.encode16(:crypto.hash(:sha256, context.database), case: :lower)
    assert artifact.path == Path.join(context.directory, "#{digest}.mmdb")
    assert artifact.digest == digest
    assert artifact.size == byte_size(context.database)
    assert artifact.source_url == url
    assert artifact.metadata["database_type"] == "GeoIP2-City"
    assert {:ok, _} = Jason.encode(artifact.metadata)
    assert File.read!(artifact.path) == context.database
    assert Bitwise.band(File.stat!(artifact.path).mode, 0o222) == 0
    assert File.ls!(context.directory) == ["#{digest}.mmdb"]
  end

  test "accepts a structurally valid synthetic Country MMDB", %{directory: directory} do
    database = synthetic_database("GeoIP2-Country")
    assert {:ok, _, _, _} = MMDB2Decoder.parse_database(database)
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(database))
    assert {:ok, artifact} = GeoIPDownload.fetch(:country, directory, url: url)
    assert artifact.metadata["database_type"] == "GeoIP2-Country"
  end

  test "rejects the wrong dataset and preserves an earlier artifact", context do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database))
    assert {:ok, artifact} = GeoIPDownload.fetch(:city, context.directory, url: url)
    {wrong_url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database))

    assert {:error, {:wrong_dataset, "GeoIP2-City"}} =
             GeoIPDownload.fetch(:country, context.directory, url: wrong_url)

    assert File.read!(artifact.path) == context.database
    assert length(File.ls!(context.directory)) == 1
  end

  test "rejects malformed metadata", %{directory: directory} do
    database = synthetic_database("GeoIP2-City", %{"ip_version" => 5})
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(database))
    assert {:error, :invalid_metadata} = GeoIPDownload.fetch(:city, directory, url: url)
    assert File.ls!(directory) == []
  end

  test "rejects non-200 and redirects without following them", context do
    for status <- [201, 301, 404, 500] do
      {url, _server} =
        GeoIPDownloadFixture.start(status, "failure", headers: [{"Location", "/next"}])

      assert {:error, {:http_status, ^status}} =
               GeoIPDownload.fetch(:city, context.directory, url: url)

      assert File.ls!(context.directory) == []
    end
  end

  test "rejects partial and multipart responses", context do
    for headers <- [
          [{"Content-Range", "bytes 0-10/20"}],
          [{"Content-Type", "multipart/byteranges; boundary=x"}]
        ] do
      {url, _server} =
        GeoIPDownloadFixture.start(206, :zlib.gzip(context.database), headers: headers)

      assert {:error, {:http_status, 206}} =
               GeoIPDownload.fetch(:city, context.directory, url: url)

      assert File.ls!(context.directory) == []
    end
  end

  test "rejects a 206 response even when Content-Range is omitted", context do
    {url, _server} = GeoIPDownloadFixture.start(206, :zlib.gzip(context.database))

    assert {:error, {:http_status, 206}} =
             GeoIPDownload.fetch(:city, context.directory, url: url)

    assert File.ls!(context.directory) == []
  end

  test "rejects truncated HTTP transfers", context do
    compressed = :zlib.gzip(context.database)

    {url, _server} =
      GeoIPDownloadFixture.start(200, compressed, content_length: byte_size(compressed) + 1)

    assert {:error, _reason} =
             GeoIPDownload.fetch(:city, context.directory, url: url, timeout: 500)

    assert File.ls!(context.directory) == []
  end

  test "rejects invalid gzip and incomplete or corrupt trailers", context do
    compressed = :zlib.gzip(context.database)

    <<prefix::binary-size(byte_size(compressed) - 8), checksum::little-32, size::little-32>> =
      compressed

    invalid = [
      "not gzip",
      prefix,
      prefix <> <<Bitwise.bxor(checksum, 1)::little-32, size::little-32>>
    ]

    for body <- invalid do
      {url, _server} = GeoIPDownloadFixture.start(200, body)
      assert {:error, :invalid_gzip} = GeoIPDownload.fetch(:city, context.directory, url: url)
      assert File.ls!(context.directory) == []
    end
  end

  test "rejects valid gzip containing an invalid MMDB", %{directory: directory} do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip("not a database"))

    assert {:error, {:invalid_database, _reason}} =
             GeoIPDownload.fetch(:city, directory, url: url)

    assert File.ls!(directory) == []
  end

  test "enforces compressed transfer limits", context do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database))

    assert {:error, :compressed_limit} =
             GeoIPDownload.fetch(:city, context.directory, url: url, max_compressed_bytes: 64)

    assert File.ls!(context.directory) == []
  end

  test "bounds chunked transfers without a declared size", context do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database), chunked: true)

    assert {:error, _reason} =
             GeoIPDownload.fetch(:city, context.directory, url: url, max_compressed_bytes: 64)

    assert File.ls!(context.directory) == []
  end

  test "accepts bounded chunked transfers", context do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database), chunked: true)
    assert {:ok, artifact} = GeoIPDownload.fetch(:city, context.directory, url: url)
    assert File.read!(artifact.path) == context.database
  end

  test "bounds inflated output, including highly compressible input", context do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(:binary.copy("x", 1_000_000)))

    assert {:error, :decompressed_limit} =
             GeoIPDownload.fetch(:city, context.directory,
               url: url,
               max_decompressed_bytes: 32_000
             )

    assert File.ls!(context.directory) == []
  end

  test "enforces a total deadline and cleans temporary files", context do
    {url, _server} =
      GeoIPDownloadFixture.start(200, :zlib.gzip(context.database), body_delay: 500)

    assert {:error, :timeout} =
             GeoIPDownload.fetch(:city, context.directory, url: url, timeout: 50)

    assert File.ls!(context.directory) == []
  end

  test "cleans request resources and files when the caller is killed", context do
    {url, server} = GeoIPDownloadFixture.start(200, "", content_length: 100, hold: true)

    caller =
      spawn(fn -> GeoIPDownload.fetch(:city, context.directory, url: url, timeout: 5_000) end)

    assert_receive {:geo_ip_fixture_request, ^server}, 1_000
    wait_until(fn -> File.ls!(context.directory) != [] end)
    monitors = elem(Process.info(caller, :monitors), 1)
    assert [{:process, owner}] = monitors
    owner_monitor = Process.monitor(owner)
    {:monitors, owner_monitors} = Process.info(owner, :monitors)

    worker =
      Enum.find_value(owner_monitors, fn {:process, process} ->
        if process != caller, do: process
      end)

    assert is_pid(worker)
    worker_monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
    assert_receive {:geo_ip_fixture_closed, ^server, {:error, :closed}}, 1_000
    assert File.ls!(context.directory) == []
  end

  test "a new valid artifact never mutates previously published bytes", context do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database))
    assert {:ok, first} = GeoIPDownload.fetch(:city, context.directory, url: url)
    next_database = synthetic_database("GeoIP2-City")
    {next_url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(next_database))
    assert {:ok, second} = GeoIPDownload.fetch(:city, context.directory, url: next_url)
    assert first.path != second.path
    assert File.read!(first.path) == context.database
    assert File.read!(second.path) == next_database
    assert length(File.ls!(context.directory)) == 2
  end

  test "reuses only a verified read-only existing digest artifact", context do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database))
    assert {:ok, first} = GeoIPDownload.fetch(:city, context.directory, url: url)
    before_stat = File.stat!(first.path)
    {next_url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database))
    assert {:ok, second} = GeoIPDownload.fetch(:city, context.directory, url: next_url)
    assert first.path == second.path
    assert File.stat!(first.path).inode == before_stat.inode
    assert File.stat!(first.path).mtime == before_stat.mtime
  end

  test "never replaces a corrupt existing digest path", context do
    digest = Base.encode16(:crypto.hash(:sha256, context.database), case: :lower)
    path = Path.join(context.directory, "#{digest}.mmdb")
    File.write!(path, "previous corrupt artifact")
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database))
    assert {:error, :artifact_conflict} = GeoIPDownload.fetch(:city, context.directory, url: url)
    assert File.read!(path) == "previous corrupt artifact"
    assert File.ls!(context.directory) == ["#{digest}.mmdb"]
  end

  test "does not follow a symlink at the immutable artifact path", context do
    digest = Base.encode16(:crypto.hash(:sha256, context.database), case: :lower)
    target = Path.join(context.directory, "previous.mmdb")
    File.write!(target, context.database)
    File.chmod!(target, 0o444)
    path = Path.join(context.directory, "#{digest}.mmdb")
    File.ln_s!(target, path)
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(context.database))
    assert {:error, :artifact_conflict} = GeoIPDownload.fetch(:city, context.directory, url: url)
    assert File.lstat!(path).type == :symlink
  end

  test "rejects invalid URLs, unsupported types and unbounded options", %{directory: directory} do
    for url <- [
          "file:///tmp/db.gz",
          "ftp://host/db.gz",
          "http://user:secret@localhost/db",
          "http:///db",
          "http://localhost/db#fragment",
          "http://localhost/\r\n"
        ] do
      assert {:error, :invalid_url} = GeoIPDownload.fetch(:city, directory, url: url)
    end

    assert {:error, :invalid_type} = GeoIPDownload.fetch(:asn, directory)

    for opts <- [
          [timeout: 120_001],
          [timeout: 0],
          [max_compressed_bytes: 64 * 1024 * 1024 + 1],
          [max_decompressed_bytes: 256 * 1024 * 1024 + 1],
          [max_decompressed_bytes: -1],
          [unknown: true]
        ] do
      assert {:error, :invalid_options} = GeoIPDownload.fetch(:city, directory, opts)
    end

    assert File.ls!(directory) == []
  end

  defp wait_until(predicate, attempts \\ 100)
  defp wait_until(_predicate, 0), do: flunk("condition did not become true")

  defp wait_until(predicate, attempts) do
    unless predicate.() do
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end

  defp synthetic_database(type, overrides \\ %{}) do
    metadata =
      Map.merge(
        %{
          "binary_format_major_version" => 2,
          "binary_format_minor_version" => 0,
          "build_epoch" => 1_750_000_000,
          "database_type" => type,
          "description" => %{"en" => "Synthetic test database"},
          "ip_version" => 4,
          "languages" => ["en"],
          "node_count" => 1,
          "record_size" => 24
        },
        overrides
      )

    <<0, 0, 1, 0, 0, 1>> <>
      :binary.copy(<<0>>, 16) <> <<0xAB, 0xCD, 0xEF>> <> "MaxMind.com" <> encode_mmdb(metadata)
  end

  defp encode_mmdb(value) when is_map(value) do
    <<7::3, map_size(value)::5>> <>
      Enum.map_join(value, fn {key, item} -> encode_mmdb(key) <> encode_mmdb(item) end)
  end

  defp encode_mmdb(value) when is_binary(value), do: <<2::3, byte_size(value)::5>> <> value
  defp encode_mmdb(value) when is_integer(value), do: <<6::3, 4::5, value::32>>

  defp encode_mmdb(value) when is_list(value),
    do: <<0::3, length(value)::5, 4>> <> Enum.map_join(value, &encode_mmdb/1)
end
