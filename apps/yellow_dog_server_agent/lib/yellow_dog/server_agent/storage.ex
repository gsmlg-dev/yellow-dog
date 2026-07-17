defmodule YellowDog.ServerAgent.Storage do
  @moduledoc """
  Bounded JSON-object reads and durable local document writes.
  """

  alias YellowDog.ServerAgent.Storage.FileOps
  alias YellowDog.Sync.Error

  @default_max_bytes 1_048_576
  @max_temp_attempts 32

  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec read(Path.t(), keyword()) :: result(map())
  def read(path, opts \\ [])

  def read(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, ops} <- file_ops(opts),
         {:ok, max_bytes} <- max_bytes(opts),
         {:ok, contents} <- call(ops, :read, [path, max_bytes]) do
      decode_object(contents)
    else
      {:error, :enoent} -> not_found()
      {:error, :eoverflow} -> oversized()
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> internal()
    end
  end

  def read(_path, _opts), do: invalid()

  @spec create(Path.t(), map(), keyword()) :: result(Path.t())
  def create(path, document, opts \\ []) do
    write(path, document, :immutable, opts)
  end

  @spec replace(Path.t(), map(), keyword()) :: result(Path.t())
  def replace(path, document, opts \\ []) do
    write(path, document, :mutable, opts)
  end

  @doc false
  @spec reconcile_timeout(Path.t(), map(), keyword()) :: result(Path.t())
  def reconcile_timeout(path, document, opts \\ [])

  def reconcile_timeout(path, document, opts) when is_binary(path) and is_map(document) do
    case read(path, opts) do
      {:ok, ^document} -> {:ok, path}
      _other -> timeout()
    end
  end

  def reconcile_timeout(_path, _document, _opts), do: invalid()

  defp write(path, document, mode, opts)
       when is_binary(path) and is_map(document) and mode in [:immutable, :mutable] and
              is_list(opts) do
    with {:ok, contents} <- encode_object(document),
         {:ok, ops} <- file_ops(opts),
         :ok <- ensure_parent(path, ops),
         {:ok, temporary_path} <- temporary_path(path, ops) do
      operation = fn -> commit(ops, temporary_path, path, contents, mode, document, opts) end

      case run(operation, timeout_ms(opts)) do
        {:ok, ^path} = result ->
          result

        {:error, :timeout} ->
          cleanup(ops, temporary_path)
          reconcile_timeout(path, document, Keyword.put(opts, :file_ops, ops))

        {:error, :conflict} ->
          cleanup(ops, temporary_path)
          conflict()

        {:error, _reason} ->
          cleanup(ops, temporary_path)
          internal()
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> internal()
    end
  end

  defp write(_path, _document, _mode, _opts), do: invalid()

  defp commit(ops, temporary_path, path, contents, :mutable, _document, _opts) do
    with :ok <- write_temporary(ops, temporary_path, contents),
         :ok <- phase(ops, :rename, [temporary_path, path]),
         :ok <- sync_directory(ops, Path.dirname(path)) do
      {:ok, path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit(ops, temporary_path, path, contents, :immutable, document, opts) do
    with :ok <- write_temporary(ops, temporary_path, contents) do
      case phase(ops, :link, [temporary_path, path]) do
        :ok ->
          cleanup(ops, temporary_path)

          case sync_directory(ops, Path.dirname(path)) do
            :ok -> {:ok, path}
            {:error, reason} -> {:error, reason}
          end

        {:error, :eexist} ->
          cleanup(ops, temporary_path)

          case read(path, Keyword.put(opts, :file_ops, ops)) do
            {:ok, ^document} -> {:ok, path}
            {:ok, _other} -> {:error, :conflict}
            {:error, _error} -> {:error, :conflict}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp write_temporary(ops, temporary_path, contents) do
    with {:ok, device} <- phase(ops, :open, [temporary_path]) do
      write_result =
        with :ok <- phase(ops, :write, [device, contents]),
             :ok <- phase(ops, :sync, [device]) do
          :ok
        end

      close_result = close_temporary(ops, device)

      case {write_result, close_result} do
        {:ok, :ok} -> :ok
        {{:error, reason}, _close_result} -> {:error, reason}
        {:ok, {:error, reason}} -> {:error, reason}
      end
    end
  end

  defp ensure_parent(path, ops), do: phase(ops, :mkdir_p, [Path.dirname(path)])

  defp close_temporary(ops, device) do
    case phase(ops, :close, [device]) do
      :ok ->
        :ok

      {:error, reason} ->
        _result = phase(ops, :close, [device])
        {:error, reason}
    end
  end

  defp temporary_path(path, ops), do: temporary_path(path, ops, 0)

  defp temporary_path(_path, _ops, @max_temp_attempts), do: {:error, :eexist}

  defp temporary_path(path, ops, attempt) do
    temporary_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}.stage"
      )

    case phase(ops, :exists?, [temporary_path]) do
      false -> {:ok, temporary_path}
      true -> temporary_path(path, ops, attempt + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_directory(ops, directory) do
    if function_exported?(ops, :sync_dir, 1) do
      phase(ops, :sync_dir, [directory])
    else
      :ok
    end
  end

  defp run(operation, nil), do: operation.()

  defp run(operation, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    caller = self()
    token = make_ref()
    {worker, monitor} = spawn_monitor(fn -> send(caller, {token, operation.()}) end)

    receive do
      {^token, result} ->
        await_down(worker, monitor)
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        receive do
          {^token, result} -> result
        after
          0 -> {:error, :operation_exit}
        end
    after
      timeout_ms ->
        Process.exit(worker, :kill)
        await_down(worker, monitor)
        {:error, :timeout}
    end
  end

  defp run(_operation, _timeout_ms), do: {:error, :invalid_timeout}

  defp await_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp encode_object(document) when is_map(document) do
    case Jason.encode(document) do
      {:ok, contents} -> {:ok, contents}
      {:error, _reason} -> invalid()
    end
  end

  defp decode_object(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> invalid()
    end
  end

  defp decode_object(_contents), do: invalid()

  defp file_ops(opts) do
    case Keyword.get(opts, :file_ops, FileOps) do
      ops when is_atom(ops) ->
        if Code.ensure_loaded?(ops), do: {:ok, ops}, else: invalid()

      _other ->
        invalid()
    end
  end

  defp max_bytes(opts) do
    case Keyword.get(opts, :max_bytes, @default_max_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 -> {:ok, max_bytes}
      _other -> invalid()
    end
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> nil
      timeout_ms when is_integer(timeout_ms) and timeout_ms >= 0 -> timeout_ms
      _other -> :invalid
    end
  end

  defp phase(ops, function, arguments), do: call(ops, function, arguments)

  defp call(ops, function, arguments) do
    if function_exported?(ops, function, length(arguments)) do
      apply(ops, function, arguments)
    else
      {:error, :unsupported_file_ops}
    end
  rescue
    _exception -> {:error, :file_exception}
  catch
    _kind, _reason -> {:error, :file_exit}
  end

  defp cleanup(ops, path) do
    _result = call(ops, :rm, [path])
    :ok
  end

  defp not_found, do: {:error, %Error{code: :not_found, message: "storage document not found"}}

  defp oversized,
    do: {:error, %Error{code: :invalid, message: "storage document exceeds size limit"}}

  defp invalid, do: {:error, %Error{code: :invalid, message: "invalid storage document"}}
  defp conflict, do: {:error, %Error{code: :conflict, message: "storage document conflicts"}}
  defp timeout, do: {:error, %Error{code: :timeout, message: "storage operation timed out"}}
  defp internal, do: {:error, %Error{code: :internal, message: "storage operation failed"}}
end

defmodule YellowDog.ServerAgent.Storage.FileOps do
  @moduledoc false

  @callback read(Path.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  @callback mkdir_p(Path.t()) :: :ok | {:error, term()}
  @callback exists?(Path.t()) :: boolean() | {:error, term()}
  @callback open(Path.t()) :: {:ok, term()} | {:error, term()}
  @callback write(term(), binary()) :: :ok | {:error, term()}
  @callback sync(term()) :: :ok | {:error, term()}
  @callback close(term()) :: :ok | {:error, term()}
  @callback rename(Path.t(), Path.t()) :: :ok | {:error, term()}
  @callback link(Path.t(), Path.t()) :: :ok | {:error, term()}
  @callback rm(Path.t()) :: :ok | {:error, term()}
  @callback sync_dir(Path.t()) :: :ok | {:error, term()}

  @spec read(Path.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def read(path, max_bytes) do
    with {:ok, device} <- :file.open(path, [:read, :binary, :raw]) do
      result =
        case :file.read(device, max_bytes + 1) do
          {:ok, contents} when byte_size(contents) <= max_bytes -> {:ok, contents}
          {:ok, _contents} -> {:error, :eoverflow}
          :eof -> {:ok, <<>>}
          {:error, reason} -> {:error, reason}
        end

      _result = :file.close(device)
      result
    end
  end

  def mkdir_p(path), do: File.mkdir_p(path)
  def exists?(path), do: File.exists?(path)
  def open(path), do: :file.open(path, [:write, :exclusive, :binary, :raw])
  def write(device, contents), do: :file.write(device, contents)
  def sync(device), do: :file.sync(device)
  def close(device), do: :file.close(device)
  def rename(source, target), do: :file.rename(source, target)
  def link(source, target), do: :file.make_link(source, target)
  def rm(path), do: File.rm(path)

  def sync_dir(directory) do
    with {:ok, device} <- :file.open(directory, [:read, :raw, :directory]) do
      result = :file.sync(device)
      _result = :file.close(device)
      result
    else
      {:error, :enotsup} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
