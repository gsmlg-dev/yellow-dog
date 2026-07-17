defmodule YellowDog.Config.Manager.Storage do
  @moduledoc false

  @max_open_attempts 32

  defmodule FileOps do
    @moduledoc false

    def read(path), do: File.read(path)
    def mkdir_p(path), do: File.mkdir_p(path)
    def ls(path), do: File.ls(path)
    def rm(path), do: File.rm(path)
    def chmod(path, mode), do: File.chmod(path, mode)
    def open(path, modes), do: :file.open(path, modes)
    def write(device, contents), do: :file.write(device, contents)
    def sync(device), do: :file.sync(device)
    def close(device), do: :file.close(device)
    def rename(source, target), do: :file.rename(source, target)

    def sync_directory(path) do
      case :file.open(path, [:read, :raw]) do
        {:ok, device} ->
          result = :file.sync(device)
          close_result = :file.close(device)
          if result == :ok, do: close_result, else: result

        {:error, reason} when reason in [:eisdir, :enotsup, :eacces, :eperm] ->
          :unsupported

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec read(Path.t(), module() | {module(), term()}) :: {:ok, binary()} | {:error, term()}
  def read(path, file_ops), do: invoke(file_ops, :read, [path])

  @spec list(Path.t(), module() | {module(), term()}) :: {:ok, [String.t()]} | {:error, term()}
  def list(path, file_ops), do: invoke(file_ops, :ls, [path])

  @spec replace(Path.t(), binary(), module() | {module(), term()}) :: :ok | {:error, term()}
  def replace(path, contents, file_ops) when is_binary(path) and is_binary(contents) do
    with :ok <- ensure_parent(path, file_ops),
         {:ok, temporary_path, device} <- open_temporary(path, file_ops) do
      result =
        with :ok <- write_sync_close(device, contents, file_ops),
             :ok <- invoke(file_ops, :rename, [temporary_path, path]),
             :ok <- sync_directory(Path.dirname(path), file_ops) do
          :ok
        end

      if result != :ok, do: invoke(file_ops, :rm, [temporary_path])
      result
    end
  end

  @spec create(Path.t(), binary(), module() | {module(), term()}) ::
          :ok | {:error, term()}
  def create(path, contents, file_ops) when is_binary(path) and is_binary(contents) do
    with :ok <- ensure_parent(path, file_ops),
         {:ok, device} <-
           invoke(file_ops, :open, [path, [:write, :exclusive, :binary, :raw]]),
         :ok <- write_sync_close(device, contents, file_ops),
         :ok <- sync_directory(Path.dirname(path), file_ops) do
      _ = invoke(file_ops, :chmod, [path, 0o600])
      :ok
    else
      {:error, _reason} = error ->
        _ = invoke(file_ops, :rm, [path])
        error
    end
  end

  @spec write_term(Path.t(), term(), module() | {module(), term()}) :: :ok | {:error, term()}
  def write_term(path, value, file_ops) do
    create(path, :erlang.term_to_binary(value, [:deterministic]), file_ops)
  end

  @spec read_term(Path.t(), module() | {module(), term()}) :: {:ok, term()} | {:error, term()}
  def read_term(path, file_ops) do
    with {:ok, contents} <- read(path, file_ops) do
      try do
        {:ok, :erlang.binary_to_term(contents, [:safe])}
      rescue
        ArgumentError -> {:error, :invalid_history}
      end
    end
  end

  defp ensure_parent(path, file_ops) do
    directory = Path.dirname(path)

    with :ok <- invoke(file_ops, :mkdir_p, [directory]) do
      _ = invoke(file_ops, :chmod, [directory, 0o700])
      :ok
    end
  end

  defp open_temporary(path, file_ops, attempts \\ @max_open_attempts)

  defp open_temporary(_path, _file_ops, 0), do: {:error, :temporary_collision}

  defp open_temporary(path, file_ops, attempts) do
    temporary_path = temporary_path(path)

    case invoke(file_ops, :open, [
           temporary_path,
           [:write, :exclusive, :binary, :raw]
         ]) do
      {:ok, device} -> {:ok, temporary_path, device}
      {:error, :eexist} -> open_temporary(path, file_ops, attempts - 1)
      {:error, _reason} = error -> error
    end
  end

  defp write_sync_close(device, contents, file_ops) do
    result =
      with :ok <- invoke(file_ops, :write, [device, contents]),
           :ok <- invoke(file_ops, :sync, [device]) do
        :ok
      end

    close_result = invoke(file_ops, :close, [device])
    if result == :ok, do: close_result, else: result
  end

  defp sync_directory(path, file_ops) do
    case invoke(file_ops, :sync_directory, [path]) do
      :ok -> :ok
      :unsupported -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp temporary_path(path) do
    seed =
      :erlang.term_to_binary({System.unique_integer([:positive, :monotonic]), make_ref()})

    suffix =
      :crypto.hash(:sha256, seed)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{suffix}.tmp")
  end

  defp invoke({module, context}, function, arguments) do
    safe_apply(module, function, [context | arguments])
  end

  defp invoke(module, function, arguments) when is_atom(module) do
    safe_apply(module, function, arguments)
  end

  defp safe_apply(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _exception -> {:error, :file_operation_failed}
  catch
    _kind, _reason -> {:error, :file_operation_failed}
  end
end
