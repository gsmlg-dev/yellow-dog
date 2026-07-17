defmodule YellowDog.Netboot.Asset.ManagedAsset do
  @moduledoc false

  @max_id_bytes 128
  @max_filename_bytes 1_024
  @max_size 9_223_372_036_854_775_807
  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @control_pattern ~r/\p{Cc}/u
  @active_keys MapSet.new(~w(asset_id filename size blob_digest ownership lifecycle))
  @tombstoned_keys MapSet.put(@active_keys, "tombstone_filename")

  @enforce_keys [:asset_id, :filename, :size, :blob_digest, :ownership, :lifecycle]
  defstruct [
    :asset_id,
    :filename,
    :size,
    :blob_digest,
    :ownership,
    :lifecycle,
    :tombstone_filename
  ]

  @type lifecycle :: :active | :tombstoned

  @type t :: %__MODULE__{
          asset_id: String.t(),
          filename: String.t(),
          size: non_neg_integer(),
          blob_digest: String.t(),
          ownership: :managed,
          lifecycle: lifecycle(),
          tombstone_filename: String.t() | nil
        }

  @spec from_document(term()) :: {:ok, t()} | {:error, atom()}
  def from_document(document) when is_map(document) do
    with {:ok, lifecycle} <- lifecycle(document),
         :ok <- validate_keys(document, lifecycle),
         :ok <- validate_asset_id(document["asset_id"]),
         :ok <- validate_filename(document["filename"], :invalid_filename),
         :ok <- validate_distinct_owned_paths(document["asset_id"], document["filename"]),
         :ok <- validate_size(document["size"]),
         :ok <- validate_digest(document["blob_digest"]),
         :ok <- validate_ownership(document["ownership"]),
         :ok <-
           validate_tombstone(
             document["asset_id"],
             document["filename"],
             document["tombstone_filename"],
             lifecycle
           ) do
      {:ok,
       %__MODULE__{
         asset_id: document["asset_id"],
         filename: document["filename"],
         size: document["size"],
         blob_digest: document["blob_digest"],
         ownership: :managed,
         lifecycle: lifecycle,
         tombstone_filename: document["tombstone_filename"]
       }}
    end
  end

  def from_document(_document), do: {:error, :invalid_asset}

  @spec to_document(t()) :: map()
  def to_document(%__MODULE__{} = asset) do
    document = %{
      "asset_id" => asset.asset_id,
      "filename" => asset.filename,
      "size" => asset.size,
      "blob_digest" => asset.blob_digest,
      "ownership" => Atom.to_string(asset.ownership),
      "lifecycle" => Atom.to_string(asset.lifecycle)
    }

    if asset.lifecycle == :tombstoned do
      Map.put(document, "tombstone_filename", asset.tombstone_filename)
    else
      document
    end
  end

  @spec to_resource(t()) :: map()
  def to_resource(%__MODULE__{} = asset) do
    %{
      "asset_id" => asset.asset_id,
      "filename" => asset.filename,
      "size" => asset.size,
      "blob_digest" => asset.blob_digest
    }
  end

  @spec tombstone(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def tombstone(%__MODULE__{lifecycle: :active} = asset, tombstone_filename) do
    asset
    |> to_document()
    |> Map.put("lifecycle", "tombstoned")
    |> Map.put("tombstone_filename", tombstone_filename)
    |> from_document()
  end

  def tombstone(%__MODULE__{}, _tombstone_filename), do: {:error, :invalid_lifecycle}

  @spec tombstone_filename(t()) :: String.t()
  def tombstone_filename(%__MODULE__{} = asset) do
    tombstone_filename(asset.asset_id, asset.filename)
  end

  @spec owned_filenames(t()) :: [String.t()]
  def owned_filenames(%__MODULE__{} = asset) do
    [asset.filename, tombstone_filename(asset)]
  end

  defp tombstone_filename(asset_id, payload_filename) do
    digest =
      :crypto.hash(:sha256, asset_id)
      |> Base.encode16(case: :lower)

    filename = ".yellowdog-delete-#{digest}.tombstone"

    case Path.dirname(payload_filename) do
      "." -> filename
      directory -> Path.join(directory, filename)
    end
  end

  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{lifecycle: :active}), do: true
  def active?(%__MODULE__{}), do: false

  @spec valid_filename?(term()) :: boolean()
  def valid_filename?(filename), do: validate_filename(filename, :invalid_filename) == :ok

  defp lifecycle(%{"lifecycle" => "active"}), do: {:ok, :active}
  defp lifecycle(%{"lifecycle" => "tombstoned"}), do: {:ok, :tombstoned}
  defp lifecycle(_document), do: {:error, :invalid_lifecycle}

  defp validate_keys(document, :active) do
    if document |> Map.keys() |> MapSet.new() |> MapSet.equal?(@active_keys),
      do: :ok,
      else: {:error, :invalid_asset}
  end

  defp validate_keys(document, :tombstoned) do
    if document |> Map.keys() |> MapSet.new() |> MapSet.equal?(@tombstoned_keys),
      do: :ok,
      else: {:error, :invalid_asset}
  end

  defp validate_asset_id(asset_id) when is_binary(asset_id) do
    valid? =
      byte_size(asset_id) in 1..@max_id_bytes and
        String.valid?(asset_id) and
        String.normalize(asset_id, :nfc) == asset_id and
        String.printable?(asset_id) and
        not Regex.match?(@control_pattern, asset_id) and
        not String.contains?(asset_id, ["/", "\\"]) and
        asset_id not in [".", "..", "~"]

    if valid?, do: :ok, else: {:error, :invalid_asset_id}
  end

  defp validate_asset_id(_asset_id), do: {:error, :invalid_asset_id}

  defp validate_filename(filename, error) when is_binary(filename) do
    parts = Path.split(filename)

    valid? =
      byte_size(filename) in 1..@max_filename_bytes and
        String.valid?(filename) and
        String.normalize(filename, :nfc) == filename and
        String.printable?(filename) and
        not Regex.match?(@control_pattern, filename) and
        Path.type(filename) == :relative and
        not String.contains?(filename, ["\\", <<0>>]) and
        parts != [] and
        Enum.all?(parts, &(&1 not in ["", ".", ".."])) and
        Path.join(parts) == filename

    if valid?, do: :ok, else: {:error, error}
  end

  defp validate_filename(_filename, error), do: {:error, error}

  defp validate_size(size) when is_integer(size) and size in 0..@max_size, do: :ok
  defp validate_size(_size), do: {:error, :invalid_size}

  defp validate_digest(digest) when is_binary(digest) do
    if Regex.match?(@digest_pattern, digest), do: :ok, else: {:error, :invalid_digest}
  end

  defp validate_digest(_digest), do: {:error, :invalid_digest}

  defp validate_ownership("managed"), do: :ok
  defp validate_ownership(_ownership), do: {:error, :invalid_ownership}

  defp validate_distinct_owned_paths(asset_id, filename) do
    if filename == tombstone_filename(asset_id, filename),
      do: {:error, :invalid_filename},
      else: :ok
  end

  defp validate_tombstone(_asset_id, _filename, nil, :active), do: :ok

  defp validate_tombstone(asset_id, filename, tombstone, :tombstoned) do
    with :ok <- validate_filename(tombstone, :invalid_tombstone_filename),
         true <- tombstone == tombstone_filename(asset_id, filename) do
      :ok
    else
      _ -> {:error, :invalid_tombstone_filename}
    end
  end

  defp validate_tombstone(_asset_id, _filename, _tombstone_filename, _lifecycle),
    do: {:error, :invalid_asset}
end
