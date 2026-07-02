defmodule GeoIpDb.Download do
  @moduledoc """
  Downloads DB-IP.com lite databases in MMDB format.

  Handles URL construction, HTTP download via `http_fetch`, gzip decompression,
  and file storage. Used by both `GeoIpDb.Database` (runtime) and
  `Mix.Tasks.GeoIpDb.Download` (dev).
  """

  require Logger

  @db_ip_base_url "https://download.db-ip.com/free"

  @type database_type :: :city | :country

  @doc """
  Downloads a DB-IP lite database, decompresses it, and saves to disk.

  Returns `{:ok, path}` on success or `{:error, reason}` on failure.

  ## Options

    - `:target_dir` - directory to save the file (default: `priv/data`)
    - `:fetcher` - function used to fetch the database URL
  """
  @spec download(database_type(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def download(type, opts \\ []) when type in [:city, :country] do
    target_path = target_path(type, opts)
    target_path |> Path.dirname() |> File.mkdir_p!()

    url = download_url(type)
    fetcher = Keyword.get(opts, :fetcher, &default_fetch/1)

    Logger.info("[GeoIpDb] Downloading database", type: type, url: url)

    case fetcher.(url) do
      %HTTP.Response{ok: true} = response ->
        with {:ok, body} <- response_body(response) do
          decompress_and_save(body, target_path, type)
        end

      %HTTP.Response{status: status} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:download_failed, reason}}
    end
  end

  @doc """
  Returns the download URL for the current month's database.
  """
  @spec download_url(database_type()) :: String.t()
  def download_url(type) do
    {{year, month, _day}, _time} = :calendar.local_time()
    month_str = String.pad_leading("#{month}", 2, "0")
    "#{@db_ip_base_url}/dbip-#{type}-lite-#{year}-#{month_str}.mmdb.gz"
  end

  @doc """
  Returns the filename for a database type.
  """
  @spec filename(database_type()) :: String.t()
  def filename(type), do: "dbip-#{type}-lite.mmdb"

  @doc """
  Returns the target file path for a database type.
  """
  @spec target_path(database_type(), keyword()) :: Path.t()
  def target_path(type, opts \\ []) do
    dir = Keyword.get_lazy(opts, :target_dir, fn -> default_data_dir() end)
    Path.join(dir, filename(type))
  end

  defp default_data_dir do
    priv_dir = :code.priv_dir(:geo_ip_db)
    Path.join(to_string(priv_dir), "data")
  end

  defp default_fetch(url) do
    Application.ensure_all_started(:http_fetch)
    url |> HTTP.fetch() |> HTTP.Promise.await()
  end

  defp response_body(%HTTP.Response{} = response) do
    {:ok, HTTP.Response.read_all(response)}
  rescue
    exception -> {:error, {:read_failed, Exception.message(exception)}}
  end

  defp decompress_and_save(compressed, target_path, type) do
    try do
      data = :zlib.gunzip(compressed)

      with {:ok, ^target_path} <- replace_file(target_path, data, &validate_database_file/1) do
        Logger.info("[GeoIpDb] Saved database", type: type, path: target_path)
        {:ok, target_path}
      end
    rescue
      e -> {:error, {:decompress_failed, Exception.message(e)}}
    end
  end

  defp validate_database_file(path) do
    with {:ok, data} <- File.read(path) do
      case MMDB2Decoder.parse_database(data) do
        {:ok, _meta, _tree, _db_data} -> :ok
        {:error, reason} -> {:error, {:invalid_database, reason}}
      end
    end
  end

  defp replace_file(target_path, data, validator) do
    tmp_path = "#{target_path}.#{System.unique_integer([:positive, :monotonic])}.tmp"

    result =
      case File.write(tmp_path, data) do
        :ok ->
          with :ok <- validate_tmp_file(tmp_path, validator),
               :ok <- File.rename(tmp_path, target_path) do
            {:ok, target_path}
          else
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, {:write_failed, reason}}
      end

    case result do
      {:ok, ^target_path} ->
        {:ok, target_path}

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp validate_tmp_file(tmp_path, validator) do
    validator.(tmp_path)
  rescue
    exception -> {:error, {:invalid_database, exception}}
  catch
    kind, reason -> {:error, {:invalid_database, {kind, reason}}}
  end
end
