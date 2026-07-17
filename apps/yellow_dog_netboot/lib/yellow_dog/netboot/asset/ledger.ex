defmodule YellowDog.Netboot.Asset.Ledger do
  @moduledoc false

  alias YellowDog.Netboot.Asset.ManagedAsset
  alias YellowDog.Netboot.ManagedStorage.AtomicJson

  @version 1
  @max_assets 1_000
  @empty_document %{"version" => @version, "assets" => []}

  defstruct assets: %{}

  @type t :: %__MODULE__{assets: %{String.t() => ManagedAsset.t()}}

  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def load(path, opts \\ []) do
    with {:ok, document} <- AtomicJson.read(path, @empty_document, opts),
         {:ok, ledger} <- from_document(document) do
      {:ok, ledger}
    end
  end

  @spec write(Path.t(), t(), keyword()) :: :ok | {:error, atom()}
  def write(path, %__MODULE__{} = ledger, opts \\ []) do
    with {:ok, validated} <- from_document(to_document(ledger)) do
      AtomicJson.write(path, to_document(validated), opts)
    end
  end

  @spec fetch(t(), String.t()) :: {:ok, ManagedAsset.t()} | {:error, :not_found}
  def fetch(%__MODULE__{assets: assets}, asset_id) do
    case Map.fetch(assets, asset_id) do
      {:ok, asset} -> {:ok, asset}
      :error -> {:error, :not_found}
    end
  end

  @spec list(t()) :: [ManagedAsset.t()]
  def list(%__MODULE__{assets: assets}) do
    assets
    |> Map.values()
    |> Enum.sort_by(& &1.asset_id)
  end

  @spec list_active(t()) :: [ManagedAsset.t()]
  def list_active(%__MODULE__{} = ledger) do
    Enum.filter(list(ledger), &ManagedAsset.active?/1)
  end

  @spec put(t(), ManagedAsset.t()) :: {:ok, t()} | {:error, atom()}
  def put(%__MODULE__{} = ledger, %ManagedAsset{} = asset) do
    with {:ok, asset} <- validate_asset(asset) do
      cond do
        Map.has_key?(ledger.assets, asset.asset_id) ->
          {:error, :duplicate_asset_id}

        filename_taken?(ledger, asset.filename) ->
          {:error, :duplicate_filename}

        true ->
          {:ok, %{ledger | assets: Map.put(ledger.assets, asset.asset_id, asset)}}
      end
    end
  end

  @spec to_document(t()) :: map()
  def to_document(%__MODULE__{} = ledger) do
    %{
      "version" => @version,
      "assets" => Enum.map(list(ledger), &ManagedAsset.to_document/1)
    }
  end

  defp from_document(%{"version" => @version, "assets" => assets} = document)
       when map_size(document) == 2 and is_list(assets) and length(assets) <= @max_assets do
    Enum.reduce_while(assets, {:ok, empty()}, fn document, {:ok, ledger} ->
      with {:ok, asset} <- ManagedAsset.from_document(document),
           {:ok, ledger} <- put(ledger, asset) do
        {:cont, {:ok, ledger}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp from_document(_document), do: {:error, :invalid_ledger}

  defp validate_asset(%ManagedAsset{} = asset) do
    asset
    |> ManagedAsset.to_document()
    |> ManagedAsset.from_document()
  end

  defp filename_taken?(ledger, filename) do
    Enum.any?(ledger.assets, fn {_asset_id, asset} ->
      asset.filename == filename
    end)
  end
end
