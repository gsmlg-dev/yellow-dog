defmodule GeoIpDb.Application do
  @moduledoc """
  OTP Application for GeoIpDb.

  Starts the database server that loads and serves MMDB database files
  for IP geolocation lookups.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GeoIpDb.Database
    ]

    opts = [strategy: :one_for_one, name: GeoIpDb.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
