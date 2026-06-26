defmodule YellowDog.Tasks.RegionData.CountriesProvider do
  @moduledoc """
  Region data provider backed by the existing GeoIP country list.
  """

  @behaviour YellowDog.Tasks.RegionData.Provider

  @impl true
  def list_countries do
    countries =
      GeoIpDb.Countries.list()
      |> Enum.map(fn %{code: code, name: name} ->
        %{
          "code" => code,
          "name" => name,
          "regions" => []
        }
      end)

    {:ok, countries}
  end
end
