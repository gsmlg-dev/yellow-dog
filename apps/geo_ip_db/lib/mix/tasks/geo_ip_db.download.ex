defmodule Mix.Tasks.GeoIpDb.Download do
  @moduledoc """
  Downloads the DB-IP.com city lite database.

  ## Usage

      mix geo_ip_db.download

  This will download the latest DB-IP City Lite database in MMDB format
  to `priv/data/dbip-city-lite.mmdb`.

  ## Options

      --force    Overwrite existing database file
      --country  Download country-only database (smaller, faster)

  ## Notes

  The DB-IP Lite databases are free to use with attribution.
  See https://db-ip.com/db/download/ip-to-city-lite for details.
  """

  use Mix.Task

  @shortdoc "Downloads the DB-IP.com geolocation database"

  @db_ip_base_url "https://download.db-ip.com/free"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [force: :boolean, country: :boolean])

    # Ensure data directory exists
    priv_dir = Application.app_dir(:geo_ip_db, "priv")
    data_dir = Path.join(priv_dir, "data")
    File.mkdir_p!(data_dir)

    database_type = if opts[:country], do: "country", else: "city"
    filename = "dbip-#{database_type}-lite.mmdb"
    target_path = Path.join(data_dir, filename)

    if File.exists?(target_path) and !opts[:force] do
      Mix.shell().info("Database already exists at #{target_path}")
      Mix.shell().info("Use --force to overwrite")
      :ok
    else
      download_database(database_type, target_path)
    end
  end

  defp download_database(type, target_path) do
    # Get current year and month for the URL
    {{year, month, _day}, _time} = :calendar.local_time()
    month_str = String.pad_leading("#{month}", 2, "0")

    url = "#{@db_ip_base_url}/dbip-#{type}-lite-#{year}-#{month_str}.mmdb.gz"

    Mix.shell().info("Downloading #{url}...")

    # Ensure http_fetch application is started
    Application.ensure_all_started(:http_fetch)

    # Use http_fetch for downloading
    case HTTP.fetch(url) |> HTTP.Promise.await() do
      %HTTP.Response{ok: true, body: body} ->
        Mix.shell().info("Download complete, decompressing...")
        decompress_and_save(body, target_path)

      %HTTP.Response{status: status} ->
        Mix.shell().error("Download failed with status #{status}")

        Mix.shell().info(
          "The database URL may have changed. Please check https://db-ip.com/db/download/ip-to-#{type}-lite"
        )

        {:error, {:http_error, status}}

      {:error, reason} ->
        Mix.shell().error("Download failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp decompress_and_save(compressed, target_path) do
    case :zlib.gunzip(compressed) do
      data when is_binary(data) ->
        case File.write(target_path, data) do
          :ok ->
            Mix.shell().info("Database saved to #{target_path}")
            :ok

          {:error, reason} ->
            Mix.shell().error("Failed to write database to #{target_path}: #{inspect(reason)}")
            {:error, {:write_failed, reason}}
        end

      _ ->
        Mix.shell().error("Failed to decompress database")
        {:error, :decompress_failed}
    end
  end
end
