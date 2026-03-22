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

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [force: :boolean, country: :boolean])

    type = if opts[:country], do: :country, else: :city
    target_path = GeoIpDb.Download.target_path(type)

    if File.exists?(target_path) and !opts[:force] do
      Mix.shell().info("Database already exists at #{target_path}")
      Mix.shell().info("Use --force to overwrite")
      :ok
    else
      Mix.shell().info("Downloading #{GeoIpDb.Download.download_url(type)}...")

      case GeoIpDb.Download.download(type) do
        {:ok, path} ->
          Mix.shell().info("Database saved to #{path}")
          :ok

        {:error, {:http_error, status}} ->
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
  end
end
