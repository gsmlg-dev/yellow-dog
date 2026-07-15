defmodule YellowDog.Management.Storage.AtomicJson do
  @moduledoc """
  Durable JSON reads plus immutable creation and atomic replacement.
  """

  alias YellowDog.Sync.Error

  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec read(Path.t()) :: result(term())
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> not_found()
      {:error, reason} -> file_error(reason)
    end
  rescue
    _exception -> invalid()
  end

  def read(_path), do: invalid()

  @spec create(Path.t(), term()) :: result(Path.t())
  def create(path, value) when is_binary(path) do
    with {:ok, contents} <- encode(value),
         :ok <- mkdir_parent(path),
         {:ok, device} <- :file.open(path, [:write, :exclusive, :binary, :raw]) do
      case write_sync_close(device, contents) do
        :ok -> {:ok, path}
        {:error, reason} -> file_error(reason)
      end
    else
      {:error, %Error{}} = error -> error
      {:error, :eexist} -> conflict()
      {:error, reason} -> file_error(reason)
    end
  rescue
    _exception -> invalid()
  end

  def create(_path, _value), do: invalid()

  @spec replace(Path.t(), term()) :: result(Path.t())
  def replace(path, value) when is_binary(path) do
    with {:ok, contents} <- encode(value),
         :ok <- mkdir_parent(path),
         {:ok, temporary_path, device} <- open_temporary(path) do
      replace_from_temporary(temporary_path, device, contents, path)
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> file_error(reason)
    end
  rescue
    _exception -> invalid()
  end

  def replace(_path, _value), do: invalid()

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> invalid()
    end
  end

  defp encode(value) do
    case Jason.encode(value) do
      {:ok, contents} -> {:ok, contents}
      {:error, _reason} -> invalid()
    end
  end

  defp mkdir_parent(path), do: File.mkdir_p(Path.dirname(path))

  defp write_sync_close(device, contents) do
    write_result =
      with :ok <- :file.write(device, contents),
           :ok <- :file.sync(device) do
        :ok
      end

    close_result = :file.close(device)

    case {write_result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close_result} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
    end
  end

  defp open_temporary(path, attempt \\ 0)

  defp open_temporary(_path, 10), do: {:error, :eexist}

  defp open_temporary(path, attempt) do
    temporary_path = temporary_path(path)

    case :file.open(temporary_path, [:write, :exclusive, :binary, :raw]) do
      {:ok, device} -> {:ok, temporary_path, device}
      {:error, :eexist} -> open_temporary(path, attempt + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_from_temporary(temporary_path, device, contents, path) do
    case write_sync_close(device, contents) do
      :ok ->
        case :file.rename(temporary_path, path) do
          :ok -> {:ok, path}
          {:error, reason} -> cleanup_temporary(temporary_path, reason)
        end

      {:error, reason} ->
        cleanup_temporary(temporary_path, reason)
    end
  end

  defp cleanup_temporary(temporary_path, reason) do
    File.rm(temporary_path)
    file_error(reason)
  end

  defp temporary_path(path) do
    Path.join([
      Path.dirname(path),
      ".#{Path.basename(path)}.#{System.unique_integer([:positive, :monotonic])}.tmp"
    ])
  end

  defp not_found,
    do: {:error, Error.new(:not_found, "JSON document not found", %{})}

  defp conflict,
    do: {:error, Error.new(:conflict, "JSON document already exists", %{})}

  defp invalid,
    do: {:error, Error.new(:invalid, "invalid JSON document", %{})}

  defp file_error(reason) do
    {:error,
     Error.new(:internal, "JSON storage operation failed", %{"reason" => inspect(reason)})}
  end
end
