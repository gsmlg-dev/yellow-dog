defmodule YellowDog.Management.Blobs do
  @moduledoc """
  Validated, digest-addressed reads for management-owned blobs.
  """

  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @default_max_blob_bytes 500 * 1024 * 1024

  @read_chunk_bytes 64 * 1024

  @type blob :: %{digest: String.t(), path: Path.t(), size: non_neg_integer()}
  @type result :: {:ok, blob()} | {:error, Error.t()}

  @spec get(term()) :: result()
  def get(digest), do: get(digest, configured_max_blob_bytes())

  @spec get(term(), term()) :: result()
  def get(digest, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, digest} <- Digest.validate(digest),
         {:ok, path} <- StoragePath.blob(digest),
         {:ok, %{type: :regular}} <- file_info(path, max_bytes),
         {:ok, size} <- verify_file(path, digest, max_bytes) do
      {:ok, %{digest: digest, path: path, size: size}}
    end
  end

  def get(_digest, _max_bytes), do: invalid("invalid blob size limit", "invalid_limit")

  defp file_info(path, max_bytes) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= max_bytes ->
        {:ok, %{type: :regular}}

      {:ok, %{type: :regular}} ->
        invalid("blob exceeds configured size limit", "too_large")

      {:ok, _info} ->
        invalid("invalid blob file", "invalid_file")

      {:error, :enoent} ->
        not_found()

      {:error, _reason} ->
        internal()
    end
  rescue
    _exception -> internal()
  end

  defp verify_file(path, digest, max_bytes) do
    case File.open(path, [:read, :binary], fn device ->
           hash_device(device, :crypto.hash_init(:sha256), 0, max_bytes)
         end) do
      {:ok, {:ok, actual, size}} ->
        if :crypto.hash_equals(actual, digest) do
          {:ok, size}
        else
          invalid("blob digest verification failed", "digest_mismatch")
        end

      {:ok, {:error, %Error{}} = error} ->
        error

      {:error, :enoent} ->
        not_found()

      {:error, _reason} ->
        internal()
    end
  rescue
    _exception -> internal()
  end

  defp hash_device(device, context, size, max_bytes) do
    case IO.binread(device, @read_chunk_bytes) do
      :eof ->
        actual =
          context
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, actual, size}

      content when is_binary(content) ->
        new_size = size + byte_size(content)

        if new_size <= max_bytes do
          hash_device(
            device,
            :crypto.hash_update(context, content),
            new_size,
            max_bytes
          )
        else
          invalid("blob exceeds configured size limit", "too_large")
        end

      {:error, _reason} ->
        internal()
    end
  end

  defp configured_max_blob_bytes do
    case Application.get_env(
           :yellow_dog_management_core,
           :max_blob_bytes,
           @default_max_blob_bytes
         ) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 -> max_bytes
      _invalid -> @default_max_blob_bytes
    end
  end

  defp not_found, do: {:error, Error.new(:not_found, "blob was not found", %{})}

  defp invalid(message, reason),
    do: {:error, Error.new(:invalid, message, %{"reason" => reason})}

  defp internal, do: {:error, Error.new(:internal, "blob read failed", %{})}
end
