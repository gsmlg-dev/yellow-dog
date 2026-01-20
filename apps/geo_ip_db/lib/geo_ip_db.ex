defmodule GeoIpDb do
  @moduledoc """
  IP Geolocation database library using MMDB format.

  This library provides IP geolocation lookup capabilities using MaxMind DB format
  files (MMDB). It supports databases from providers like DB-IP.com and MaxMind.

  ## Usage

      # Lookup an IP address (uses default database)
      GeoIpDb.lookup("8.8.8.8")
      # => {:ok, %{city: "Mountain View", country: "US", ...}}

      # Lookup with specific database
      GeoIpDb.lookup("8.8.8.8", :city)

      # Get just the country
      GeoIpDb.country("8.8.8.8")
      # => {:ok, "US"}

      # Get the city
      GeoIpDb.city("8.8.8.8")
      # => {:ok, "Mountain View"}

  ## Database Configuration

  By default, the library looks for databases in `priv/data/`:
  - `dbip-city-lite.mmdb` - City-level geolocation (default)
  - `dbip-country-lite.mmdb` - Country-level geolocation

  You can configure custom database paths via application config:

      config :geo_ip_db,
        databases: %{
          city: "/path/to/city.mmdb",
          country: "/path/to/country.mmdb"
        }
  """

  alias GeoIpDb.Database

  @type ip_address :: String.t() | :inet.ip_address()
  @type database_name :: :city | :country | atom()
  @type geo_info :: %{
          optional(:city) => String.t() | nil,
          optional(:country) => String.t() | nil,
          optional(:country_code) => String.t() | nil,
          optional(:continent) => String.t() | nil,
          optional(:continent_code) => String.t() | nil,
          optional(:latitude) => float() | nil,
          optional(:longitude) => float() | nil,
          optional(:timezone) => String.t() | nil,
          optional(:postal_code) => String.t() | nil,
          optional(:subdivision) => String.t() | nil
        }

  @doc """
  Looks up geolocation information for an IP address.

  ## Parameters

    - `ip` - IP address as string ("1.2.3.4" or "2001:db8::1") or tuple
    - `database` - Database to use (default: `:city`)

  ## Returns

    - `{:ok, geo_info}` - Map with geolocation data
    - `{:error, reason}` - Error tuple

  ## Examples

      iex> GeoIpDb.lookup("8.8.8.8")
      {:ok, %{country: "United States", country_code: "US", ...}}

      iex> GeoIpDb.lookup({8, 8, 8, 8})
      {:ok, %{country: "United States", country_code: "US", ...}}
  """
  @spec lookup(ip_address(), database_name()) :: {:ok, geo_info()} | {:error, term()}
  def lookup(ip, database \\ :city) do
    with {:ok, ip_tuple} <- parse_ip(ip),
         {:ok, raw_data} <- Database.lookup(ip_tuple, database) do
      {:ok, normalize_result(raw_data)}
    end
  end

  @doc """
  Gets the country name for an IP address.

  ## Examples

      iex> GeoIpDb.country("8.8.8.8")
      {:ok, "United States"}
  """
  @spec country(ip_address(), database_name()) :: {:ok, String.t() | nil} | {:error, term()}
  def country(ip, database \\ :city) do
    case lookup(ip, database) do
      {:ok, info} -> {:ok, info[:country]}
      error -> error
    end
  end

  @doc """
  Gets the country code (ISO 3166-1 alpha-2) for an IP address.

  ## Examples

      iex> GeoIpDb.country_code("8.8.8.8")
      {:ok, "US"}
  """
  @spec country_code(ip_address(), database_name()) :: {:ok, String.t() | nil} | {:error, term()}
  def country_code(ip, database \\ :city) do
    case lookup(ip, database) do
      {:ok, info} -> {:ok, info[:country_code]}
      error -> error
    end
  end

  @doc """
  Gets the city name for an IP address.

  ## Examples

      iex> GeoIpDb.city("8.8.8.8")
      {:ok, "Mountain View"}
  """
  @spec city(ip_address(), database_name()) :: {:ok, String.t() | nil} | {:error, term()}
  def city(ip, database \\ :city) do
    case lookup(ip, database) do
      {:ok, info} -> {:ok, info[:city]}
      error -> error
    end
  end

  @doc """
  Gets the coordinates (latitude, longitude) for an IP address.

  ## Examples

      iex> GeoIpDb.coordinates("8.8.8.8")
      {:ok, {37.386, -122.0838}}
  """
  @spec coordinates(ip_address(), database_name()) ::
          {:ok, {float(), float()} | nil} | {:error, term()}
  def coordinates(ip, database \\ :city) do
    case lookup(ip, database) do
      {:ok, %{latitude: lat, longitude: lon}} when not is_nil(lat) and not is_nil(lon) ->
        {:ok, {lat, lon}}

      {:ok, _} ->
        {:ok, nil}

      error ->
        error
    end
  end

  @doc """
  Lists all loaded databases.

  ## Examples

      iex> GeoIpDb.list_databases()
      [:city, :country]
  """
  @spec list_databases() :: [database_name()]
  def list_databases do
    Database.list_databases()
  end

  @doc """
  Lists all available countries with their ISO 3166-1 alpha-2 codes.

  This is useful for building country selection UIs for geo-based ACLs.

  ## Examples

      iex> countries = GeoIpDb.list_countries()
      iex> length(countries)
      249
      iex> hd(countries)
      %{code: "AD", name: "Andorra"}
  """
  @spec list_countries() :: [%{code: String.t(), name: String.t()}]
  defdelegate list_countries, to: GeoIpDb.Countries, as: :list

  @doc """
  Gets a country by its ISO 3166-1 alpha-2 code.

  ## Examples

      iex> GeoIpDb.get_country("US")
      {:ok, %{code: "US", name: "United States"}}
  """
  @spec get_country(String.t()) ::
          {:ok, %{code: String.t(), name: String.t()}} | {:error, :not_found}
  defdelegate get_country(code), to: GeoIpDb.Countries, as: :get

  @doc """
  Searches countries by name (case-insensitive).

  ## Examples

      iex> GeoIpDb.search_countries("united")
      [%{code: "AE", name: "United Arab Emirates"}, ...]
  """
  @spec search_countries(String.t()) :: [%{code: String.t(), name: String.t()}]
  defdelegate search_countries(query), to: GeoIpDb.Countries, as: :search

  @doc """
  Gets database metadata.

  ## Examples

      iex> GeoIpDb.database_info(:city)
      {:ok, %{build_epoch: ~U[2024-01-01 00:00:00Z], ...}}
  """
  @spec database_info(database_name()) :: {:ok, map()} | {:error, term()}
  def database_info(database \\ :city) do
    Database.get_metadata(database)
  end

  @doc """
  Loads a database from a file path.

  ## Examples

      iex> GeoIpDb.load_database(:custom, "/path/to/custom.mmdb")
      :ok
  """
  @spec load_database(database_name(), Path.t()) :: :ok | {:error, term()}
  def load_database(name, path) do
    Database.load(name, path)
  end

  # Private functions

  defp parse_ip(ip) when is_binary(ip) do
    ip
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp parse_ip(ip) when is_tuple(ip), do: {:ok, ip}
  defp parse_ip(ip), do: {:error, {:invalid_ip, ip}}

  defp normalize_result(nil), do: %{}

  defp normalize_result(data) when is_map(data) do
    %{
      city: get_in(data, ["city", "names", "en"]),
      country: get_in(data, ["country", "names", "en"]),
      country_code: get_in(data, ["country", "iso_code"]),
      continent: get_in(data, ["continent", "names", "en"]),
      continent_code: get_in(data, ["continent", "code"]),
      latitude: get_in(data, ["location", "latitude"]),
      longitude: get_in(data, ["location", "longitude"]),
      timezone: get_in(data, ["location", "time_zone"]),
      postal_code: get_in(data, ["postal", "code"]),
      subdivision: get_first_subdivision(data)
    }
  end

  defp get_first_subdivision(data) do
    case get_in(data, ["subdivisions"]) do
      [first | _] -> get_in(first, ["names", "en"])
      _ -> nil
    end
  end
end
