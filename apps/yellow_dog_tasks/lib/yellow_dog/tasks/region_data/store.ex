defmodule YellowDog.Tasks.RegionData.Store do
  @moduledoc """
  JSON-backed store for synchronized country and region data.
  """

  alias YellowDog.Tasks.AtomicFile
  alias YellowDog.Tasks.RegionData.CountriesProvider

  @metadata_filename "metadata.json"
  @regions_filename "regions.json"
  @source "geo-ip-countries"

  @spec sync(keyword()) :: {:ok, map()} | {:error, term()}
  def sync(opts \\ []) do
    provider = Keyword.get(opts, :provider, CountriesProvider)

    with {:ok, countries} <- provider.list_countries(),
         :ok <- write_json(regions_path(opts), countries),
         metadata <- build_metadata(countries),
         :ok <- write_json(metadata_path(opts), metadata) do
      {:ok, metadata}
    end
  end

  @spec info(keyword()) :: map()
  def info(opts \\ []) do
    case read_metadata(metadata_path(opts)) do
      {:ok, %{} = metadata} -> metadata
      {:error, _reason} -> %{}
    end
  end

  @spec list_countries(keyword()) :: [map()]
  def list_countries(opts \\ []) do
    opts
    |> load_regions()
    |> Enum.map(fn country ->
      Map.drop(country, ["regions"])
    end)
  end

  @spec list_regions(String.t(), keyword()) :: [map()]
  def list_regions(country_code, opts \\ []) when is_binary(country_code) do
    case lookup(country_code, nil, opts) do
      {:ok, %{"regions" => regions}} when is_list(regions) -> regions
      _ -> []
    end
  end

  @spec lookup(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | :error
  def lookup(country_code, nil, opts) when is_binary(country_code) do
    opts
    |> load_regions()
    |> Enum.find(&(&1["code"] == country_code))
    |> case do
      nil -> :error
      country -> {:ok, country}
    end
  end

  def lookup(country_code, region_code, opts)
      when is_binary(country_code) and is_binary(region_code) do
    with {:ok, %{"regions" => regions}} <- lookup(country_code, nil, opts),
         %{} = region <- Enum.find(regions, &(&1["code"] == region_code)) do
      {:ok, region}
    else
      _ -> :error
    end
  end

  defp build_metadata(countries) do
    %{
      source: @source,
      record_count: length(countries),
      synced_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp load_regions(opts) do
    case read_json(regions_path(opts)) do
      {:ok, countries} when is_list(countries) -> countries
      _ -> []
    end
  end

  defp write_json(path, data) do
    with :ok <- path |> Path.dirname() |> File.mkdir_p(),
         {:ok, encoded} <- Jason.encode(data),
         {:ok, ^path} <- AtomicFile.replace(path, encoded, &validate_json_file/1) do
      :ok
    end
  end

  defp validate_json_file(path) do
    case read_json(path) do
      {:ok, _decoded} -> :ok
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp read_json(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, decoded}
    end
  end

  defp read_metadata(path) do
    with {:ok, metadata} <- read_json(path) do
      {:ok,
       %{
         source: metadata["source"],
         record_count: metadata["record_count"],
         synced_at: metadata["synced_at"]
       }}
    end
  end

  defp metadata_path(opts), do: Path.join(region_dir(opts), @metadata_filename)
  defp regions_path(opts), do: Path.join(region_dir(opts), @regions_filename)

  defp region_dir(opts) do
    opts
    |> Keyword.get_lazy(:data_dir, &default_data_dir/0)
    |> Path.join("region")
  end

  defp default_data_dir do
    try do
      YellowDog.Config.get_data_dir()
    catch
      :exit, _reason -> "data"
    end
  end
end
