defmodule YellowDog.Management.Blobs do
  @moduledoc """
  Validated, digest-addressed reads for management-owned blobs.
  """

  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @default_max_blob_bytes 500 * 1024 * 1024

  @read_chunk_bytes 64 * 1024

  defmodule Handle do
    @moduledoc false

    @enforce_keys [:device, :digest, :size]
    defstruct [:device, :digest, :size]
  end

  @opaque handle :: %Handle{
            device: term(),
            digest: String.t(),
            size: non_neg_integer()
          }
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec open(term()) :: result(handle())
  def open(digest), do: open(digest, configured_max_blob_bytes())

  @spec open(term(), term()) :: result(handle())
  def open(digest, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, digest} <- Digest.validate(digest),
         {:ok, path} <- StoragePath.blob(digest),
         {:ok, path_info} <- file_info(path, max_bytes) do
      open_verified(path, path_info, digest, max_bytes)
    end
  end

  def open(_digest, _max_bytes), do: invalid("invalid blob size limit", "invalid_limit")

  @spec digest(handle()) :: String.t()
  def digest(%Handle{digest: digest}), do: digest

  @spec size(handle()) :: non_neg_integer()
  def size(%Handle{size: size}), do: size

  @spec read(handle()) :: {:ok, binary()} | :eof | {:error, Error.t()}
  def read(%Handle{device: device}) do
    case :file.read(device, @read_chunk_bytes) do
      {:ok, content} -> {:ok, content}
      :eof -> :eof
      {:error, _reason} -> internal()
    end
  rescue
    _exception -> internal()
  catch
    _kind, _reason -> internal()
  end

  @spec close(handle()) :: :ok
  def close(%Handle{device: device}) do
    close_device(device)
  end

  defp file_info(path, max_bytes) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size} = info} when size <= max_bytes ->
        {:ok, info}

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

  defp open_verified(path, path_info, digest, max_bytes) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, device} ->
        verify_open_device(path, path_info, device, digest, max_bytes)

      {:error, :enoent} ->
        not_found()

      {:error, _reason} ->
        internal()
    end
  rescue
    _exception -> internal()
  end

  defp verify_open_device(path, path_info, device, digest, max_bytes) do
    result =
      try do
        verify_device(path, path_info, device, digest, max_bytes)
      rescue
        _exception -> internal()
      catch
        _kind, _reason -> internal()
      end

    case result do
      {:ok, size} ->
        {:ok, %Handle{device: device, digest: digest, size: size}}

      {:error, %Error{}} = error ->
        close_device(device)
        error
    end
  end

  defp verify_device(path, path_info, device, digest, max_bytes) do
    with {:ok, device_info} <- device_file_info(device, max_bytes),
         :ok <- same_file(path_info, device_info),
         {:ok, current_path_info} <- file_info(path, max_bytes),
         :ok <- same_file(current_path_info, device_info),
         {:ok, actual, size} <-
           hash_device(device, :crypto.hash_init(:sha256), 0, max_bytes),
         true <- :crypto.hash_equals(actual, digest),
         {:ok, 0} <- :file.position(device, :bof) do
      {:ok, size}
    else
      false -> invalid("blob digest verification failed", "digest_mismatch")
      {:error, %Error{}} = error -> error
      _error -> internal()
    end
  end

  defp device_file_info(device, max_bytes) do
    case :file.read_file_info(device) do
      {:ok, info} when is_tuple(info) and tuple_size(info) >= 12 ->
        validate_device_file_info(
          %{
            size: elem(info, 1),
            type: elem(info, 2),
            major_device: elem(info, 9),
            minor_device: elem(info, 10),
            inode: elem(info, 11)
          },
          max_bytes
        )

      _error ->
        internal()
    end
  end

  defp validate_device_file_info(%{type: :regular, size: size} = info, max_bytes)
       when size <= max_bytes,
       do: {:ok, info}

  defp validate_device_file_info(%{type: :regular}, _max_bytes),
    do: invalid("blob exceeds configured size limit", "too_large")

  defp validate_device_file_info(_info, _max_bytes),
    do: invalid("invalid blob file", "invalid_file")

  defp same_file(
         %{type: :regular, major_device: major, minor_device: minor, inode: inode},
         %{type: :regular, major_device: major, minor_device: minor, inode: inode}
       ),
       do: :ok

  defp same_file(_path_info, _device_info),
    do: invalid("invalid blob file", "invalid_file")

  defp hash_device(device, context, size, max_bytes) do
    case :file.read(device, @read_chunk_bytes) do
      :eof ->
        actual =
          context
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, actual, size}

      {:ok, content} ->
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

  defp close_device(device) do
    _result = :file.close(device)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
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
