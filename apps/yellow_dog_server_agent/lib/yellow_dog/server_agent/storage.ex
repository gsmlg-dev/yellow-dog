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
    if Keyword.keyword?(opts) do
      with {:ok, ops} <- file_ops(opts),
           {:ok, max_bytes} <- max_bytes(opts),
           {:ok, contents} <- phase(ops, :read, [path, max_bytes]),
           :ok <- enforce_max_bytes(contents, max_bytes) do
        decode_object(contents)
      else
        {:error, :enoent} -> not_found()
        {:error, :eoverflow} -> oversized()
        {:error, :timeout} -> timeout()
        {:error, %Error{} = error} -> {:error, error}
        {:error, _reason} -> internal()
      end
    else
      invalid()
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

  def reconcile_timeout(path, document, opts)
      when is_binary(path) and is_map(document) and is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, _contents, normalized} <- encode_object(document),
           {:ok, ops} <- file_ops(opts),
           true <- exact_document?(path, normalized, opts),
           :ok <- sync_directory(ops, Path.dirname(path)) do
        {:ok, path}
      else
        {:error, %Error{} = error} -> {:error, error}
        _result -> timeout()
      end
    else
      invalid()
    end
  end

  def reconcile_timeout(_path, _document, _opts), do: invalid()

  defp write(path, document, mode, opts)
       when is_binary(path) and is_map(document) and mode in [:immutable, :mutable] and
              is_list(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- validate_write_opts(opts),
           {:ok, contents, normalized} <- encode_object(document),
           {:ok, ops} <- file_ops(opts),
           :ok <- ensure_parent(path, ops),
           {:ok, temporary_path, device} <- open_temporary(path, ops) do
        result =
          commit(
            ops,
            temporary_path,
            device,
            path,
            contents,
            mode,
            normalized,
            opts
          )

        handle_commit_result(
          result,
          path,
          normalized,
          Keyword.put(opts, :file_ops, ops)
        )
      else
        {:error, :timeout} -> reconcile_unowned_timeout(path, document, opts)
        {:error, %Error{} = error} -> {:error, error}
        {:error, _reason} -> internal()
      end
    else
      invalid()
    end
  end

  defp write(_path, _document, _mode, _opts), do: invalid()

  defp handle_commit_result({:ok, path}, path, _normalized, _opts), do: {:ok, path}
  defp handle_commit_result({:error, :conflict}, _path, _normalized, _opts), do: conflict()

  defp handle_commit_result({:error, :timeout}, path, normalized, opts),
    do: reconcile_timeout(path, normalized, opts)

  defp handle_commit_result(_result, _path, _normalized, _opts), do: internal()

  defp reconcile_unowned_timeout(path, document, opts) do
    with {:ok, _contents, normalized} <- encode_object(document) do
      _match? = exact_document?(path, normalized, opts)
    end

    timeout()
  end

  defp commit(ops, temporary_path, device, path, contents, :mutable, _normalized, _opts) do
    case write_temporary(ops, device, contents) do
      :ok ->
        case phase(ops, :rename, [temporary_path, path]) do
          :ok ->
            case sync_directory(ops, Path.dirname(path)) do
              :ok -> {:ok, path}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            cleanup_then_error(ops, temporary_path, reason)
        end

      {:error, reason} ->
        cleanup_then_error(ops, temporary_path, reason)
    end
  end

  defp commit(
         ops,
         temporary_path,
         device,
         path,
         contents,
         :immutable,
         normalized,
         opts
       ) do
    with :ok <- write_temporary(ops, device, contents) do
      case phase(ops, :link, [temporary_path, path]) do
        :ok ->
          finish_immutable_promotion(ops, temporary_path, path)

        {:error, :eexist} ->
          case cleanup(ops, temporary_path) do
            :ok ->
              if exact_document?(path, normalized, Keyword.put(opts, :file_ops, ops)),
                do: {:ok, path},
                else: {:error, :conflict}

            {:error, _reason} ->
              {:error, :cleanup_failed}
          end

        {:error, reason} ->
          cleanup_then_error(ops, temporary_path, reason)
      end
    else
      {:error, reason} -> cleanup_then_error(ops, temporary_path, reason)
    end
  end

  defp finish_immutable_promotion(ops, temporary_path, path) do
    cleanup_result = cleanup(ops, temporary_path)
    sync_result = sync_directory(ops, Path.dirname(path))

    case {cleanup_result, sync_result} do
      {:ok, :ok} -> {:ok, path}
      {{:error, _reason}, _sync_result} -> {:error, :cleanup_failed}
      {:ok, {:error, reason}} -> {:error, reason}
    end
  end

  defp cleanup_then_error(ops, temporary_path, reason) do
    case cleanup(ops, temporary_path) do
      :ok -> {:error, reason}
      {:error, _cleanup_reason} -> {:error, :cleanup_failed}
    end
  end

  defp write_temporary(ops, device, contents) do
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

  defp open_temporary(path, ops), do: open_temporary(path, ops, 0)

  defp open_temporary(_path, _ops, @max_temp_attempts), do: {:error, :eexist}

  defp open_temporary(path, ops, attempt) do
    temporary_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}.stage"
      )

    case phase(ops, :exists?, [temporary_path]) do
      false -> acquire_temporary(path, temporary_path, ops, attempt)
      true -> open_temporary(path, ops, attempt + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquire_temporary(path, temporary_path, ops, attempt) do
    case phase(ops, :open, [temporary_path]) do
      {:ok, device} -> {:ok, temporary_path, device}
      {:error, :eexist} -> open_temporary(path, ops, attempt + 1)
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

  defp encode_object(document) when is_map(document) do
    if json_native?(document) do
      with {:ok, contents} <- Jason.encode(document),
           {:ok, normalized} <- decode_object(contents) do
        {:ok, contents, normalized}
      else
        _error -> invalid()
      end
    else
      invalid()
    end
  end

  defp encode_object(_document), do: invalid()

  defp json_native?(%_struct{}), do: false

  defp json_native?(value) when is_map(value) do
    normalized_keys =
      Enum.map(value, fn {key, _value} ->
        if is_atom(key), do: Atom.to_string(key), else: key
      end)

    Enum.all?(value, fn
      {key, nested} when is_atom(key) or is_binary(key) -> json_native?(nested)
      _entry -> false
    end) and length(Enum.uniq(normalized_keys)) == map_size(value)
  end

  defp json_native?(value) when is_list(value), do: Enum.all?(value, &json_native?/1)
  defp json_native?(value) when is_binary(value) or is_number(value), do: true
  defp json_native?(value) when value in [true, false, nil], do: true
  defp json_native?(_value), do: false

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

  defp validate_write_opts(opts) do
    if Keyword.has_key?(opts, :timeout) do
      invalid()
    else
      case max_bytes(opts) do
        {:ok, _max_bytes} -> :ok
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp enforce_max_bytes(contents, max_bytes) when byte_size(contents) <= max_bytes, do: :ok
  defp enforce_max_bytes(_contents, _max_bytes), do: {:error, :eoverflow}

  defp exact_document?(path, normalized, opts) do
    case read(path, opts) do
      {:ok, ^normalized} -> true
      _result -> false
    end
  end

  defp phase(ops, function, arguments) do
    ops
    |> call(function, arguments)
    |> validate_phase_result(function)
  end

  defp validate_phase_result({:ok, contents} = result, :read) when is_binary(contents),
    do: result

  defp validate_phase_result(value, :exists?) when is_boolean(value), do: value
  defp validate_phase_result({:ok, _device} = result, :open), do: result

  defp validate_phase_result(:ok, function)
       when function in [:mkdir_p, :write, :sync, :close, :rename, :link, :rm, :sync_dir],
       do: :ok

  defp validate_phase_result({:error, _reason} = result, _function), do: result
  defp validate_phase_result(_result, _function), do: {:error, :malformed_file_ops_return}

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
    case phase(ops, :rm, [path]) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
  @moduledoc """
  Synchronous file operations used by `YellowDog.ServerAgent.Storage`.

  Each callback must complete its filesystem side effect before returning.
  A callback must not delegate a filesystem mutation that can continue after
  the callback returns.
  """

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

      finalize_close(result, :file.close(device))
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
      finalize_close(result, :file.close(device))
    else
      {:error, :enotsup} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec finalize_close(:ok | {:ok, term()} | {:error, term()}, :ok | {:error, term()}) ::
          :ok | {:ok, term()} | {:error, term()}
  def finalize_close(operation_result, :ok), do: operation_result

  def finalize_close({:ok, _value}, {:error, close_reason}),
    do: {:error, {:close, close_reason}}

  def finalize_close(:ok, {:error, close_reason}), do: {:error, {:close, close_reason}}

  def finalize_close({:error, operation_reason}, {:error, close_reason}),
    do: {:error, {:operation_and_close, operation_reason, close_reason}}
end
