defmodule YellowDog.Management.Storage.AtomicJson do
  @moduledoc """
  Durable JSON reads plus immutable creation and atomic replacement.
  """

  alias YellowDog.Sync.Error

  @max_temp_attempts 32

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
    ops = file_ops()

    with {:ok, contents} <- encode(value),
         :ok <- mkdir_parent(path),
         {:ok, device} <- ops.open(path) do
      case write_sync_close(ops, device, contents) do
        :ok -> {:ok, path}
        {:error, reason} -> cleanup_path(ops, path, reason)
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
    ops = file_ops()

    with {:ok, contents} <- encode(value),
         :ok <- mkdir_parent(path),
         {:ok, temporary_path, device} <- open_temporary(path, ops) do
      replace_from_temporary(ops, temporary_path, device, contents, path)
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

  defp write_sync_close(ops, device, contents) do
    write_result =
      with :ok <- ops.write(device, contents),
           :ok <- ops.sync(device) do
        :ok
      end

    close_result = close(ops, device)

    case {write_result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close_result} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
    end
  end

  defp close(ops, device) do
    case ops.close(device) do
      :ok ->
        :ok

      {:error, reason} ->
        best_effort_close(ops, device)
        {:error, reason}
    end
  end

  defp best_effort_close(ops, device) do
    ops.close(device)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp open_temporary(path, ops, attempt \\ 0)

  defp open_temporary(_path, _ops, @max_temp_attempts), do: {:error, :eexist}

  defp open_temporary(path, ops, attempt) do
    temporary_path = temporary_path(path)

    case ops.open(temporary_path) do
      {:ok, device} -> {:ok, temporary_path, device}
      {:error, :eexist} -> open_temporary(path, ops, attempt + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_from_temporary(ops, temporary_path, device, contents, path) do
    case write_sync_close(ops, device, contents) do
      :ok ->
        case ops.rename(temporary_path, path) do
          :ok -> {:ok, path}
          {:error, reason} -> cleanup_path(ops, temporary_path, reason)
        end

      {:error, reason} ->
        cleanup_path(ops, temporary_path, reason)
    end
  end

  defp cleanup_path(ops, path, reason) do
    best_effort_remove(ops, path)
    file_error(reason)
  end

  defp best_effort_remove(ops, path) do
    ops.rm(path)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp temporary_path(path) do
    Path.join([
      Path.dirname(path),
      temporary_name(path)
    ])
  end

  defp temporary_name(path) do
    case Application.get_env(:yellow_dog_management_core, :atomic_json_temp_name) do
      generator when is_function(generator, 1) -> generator.(path)
      _other -> ".#{Path.basename(path)}.#{random_suffix()}.tmp"
    end
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(18)
    |> Base.url_encode64(padding: false)
  end

  defp file_ops do
    Application.get_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      YellowDog.Management.Storage.AtomicJson.FileOps
    )
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

defmodule YellowDog.Management.Storage.AtomicJson.FileOps do
  @moduledoc false

  def open(path), do: :file.open(path, [:write, :exclusive, :binary, :raw])
  def write(device, contents), do: :file.write(device, contents)
  def sync(device), do: :file.sync(device)
  def close(device), do: :file.close(device)
  def rename(source, target), do: :file.rename(source, target)
  def rm(path), do: File.rm(path)
end
