defmodule YellowDog.ServerAgent.Storage do
  @moduledoc """
  Bounded JSON-object reads and durable local document writes.
  """

  alias YellowDog.ServerAgent.Storage.FileOps
  alias YellowDog.Sync.Error

  @default_max_bytes 1_048_576
  @max_temp_attempts 32

  @type result(value) :: {:ok, value} | {:error, Error.t()}
  @type phase ::
          :mkdir
          | :open
          | :write
          | :file_sync
          | :close
          | :rename
          | :link
          | :stage_cleanup
          | :directory_sync
          | :read
  @type phase_error ::
          {:storage_phase, phase(), :timeout | :not_found | :overflow | :exists | :failure}

  @spec read(Path.t(), keyword()) :: result(map())
  def read(path, opts \\ [])

  def read(path, opts) when is_binary(path) and is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, ops} <- file_ops(opts),
           {:ok, max_bytes} <- max_bytes(opts),
           {:ok, contents} <- phase(ops, :read, :read, [path, max_bytes]),
           :ok <- enforce_max_bytes(contents, max_bytes) do
        decode_object(contents)
      else
        {:error, {:storage_phase, :read, :not_found}} -> not_found()
        {:error, {:storage_phase, :read, :overflow}} -> oversized()
        {:error, {:storage_phase, :read, :timeout}} -> timeout()
        {:error, :eoverflow} -> oversized()
        {:error, %Error{} = error} -> {:error, error}
        _error -> internal()
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

  defp write(path, document, mode, opts)
       when is_binary(path) and is_map(document) and mode in [:immutable, :mutable] and
              is_list(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- validate_write_opts(opts),
           {:ok, max_bytes} <- max_bytes(opts),
           {:ok, contents, normalized} <- encode_object(document),
           :ok <- enforce_max_bytes(contents, max_bytes),
           {:ok, ops} <- file_ops(opts),
           :ok <- ensure_parent(path, ops),
           {:ok, temporary_path, device} <- open_temporary(path, ops) do
        ops
        |> commit(temporary_path, device, path, contents, mode, normalized, max_bytes)
        |> write_result(path)
      else
        {:error, :eoverflow} -> oversized()
        {:error, %Error{} = error} -> {:error, error}
        {:error, {:storage_phase, _phase, :timeout}} -> timeout()
        _error -> internal()
      end
    else
      invalid()
    end
  end

  defp write(_path, _document, _mode, _opts), do: invalid()

  defp write_result({:ok, path}, path), do: {:ok, path}
  defp write_result({:error, :conflict}, _path), do: conflict()
  defp write_result({:error, {:storage_phase, _phase, :timeout}}, _path), do: timeout()
  defp write_result(_result, _path), do: internal()

  defp commit(ops, temporary_path, device, path, contents, :mutable, normalized, max_bytes) do
    case write_temporary(ops, device, contents) do
      :ok ->
        promote_mutable(ops, temporary_path, path, normalized, max_bytes)

      {:error, _reason} = error ->
        cleanup_then_error(ops, temporary_path, error)
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
         max_bytes
       ) do
    with :ok <- write_temporary(ops, device, contents) do
      case phase(ops, :link, :link, [temporary_path, path]) do
        :ok ->
          finish_immutable_promotion(
            ops,
            temporary_path,
            path,
            normalized,
            max_bytes
          )

        {:error, {:storage_phase, :link, :exists}} ->
          finish_immutable_eexist(ops, temporary_path, path, normalized, max_bytes)

        {:error, {:storage_phase, :link, :timeout}} = error ->
          reconcile_link_timeout(
            ops,
            temporary_path,
            path,
            normalized,
            max_bytes,
            error
          )

        {:error, _reason} = error ->
          cleanup_then_error(ops, temporary_path, error)
      end
    else
      {:error, _reason} = error -> cleanup_then_error(ops, temporary_path, error)
    end
  end

  defp promote_mutable(ops, temporary_path, path, normalized, max_bytes) do
    case phase(ops, :rename, :rename, [temporary_path, path]) do
      :ok ->
        sync_after_promotion(ops, path, normalized, max_bytes)

      {:error, {:storage_phase, :rename, :timeout}} = error ->
        reconcile_rename_timeout(
          ops,
          temporary_path,
          path,
          normalized,
          max_bytes,
          error
        )

      {:error, _reason} = error ->
        cleanup_then_error(ops, temporary_path, error)
    end
  end

  defp reconcile_rename_timeout(
         ops,
         temporary_path,
         path,
         normalized,
         max_bytes,
         timeout_error
       ) do
    case phase(ops, :rename, :exists?, [temporary_path]) do
      false ->
        case document_match(ops, path, normalized, max_bytes) do
          :exact -> sync_after_promotion(ops, path, normalized, max_bytes)
          :different -> timeout_error
          {:error, _reason} = error -> error
        end

      _stage_present_or_unknown ->
        cleanup_then_error(ops, temporary_path, timeout_error)
    end
  end

  defp finish_immutable_promotion(ops, temporary_path, path, normalized, max_bytes) do
    case cleanup(ops, temporary_path) do
      :ok -> sync_after_promotion(ops, path, normalized, max_bytes)
      {:error, _reason} = error -> error
    end
  end

  defp finish_immutable_eexist(ops, temporary_path, path, normalized, max_bytes) do
    case cleanup(ops, temporary_path) do
      :ok ->
        case document_match(ops, path, normalized, max_bytes) do
          :exact -> sync_after_promotion(ops, path, normalized, max_bytes)
          :different -> {:error, :conflict}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp reconcile_link_timeout(
         ops,
         temporary_path,
         path,
         normalized,
         max_bytes,
         timeout_error
       ) do
    case phase(ops, :link, :same_file?, [temporary_path, path]) do
      true ->
        reconcile_proven_link_timeout(
          ops,
          temporary_path,
          path,
          normalized,
          max_bytes,
          timeout_error
        )

      false ->
        cleanup_then_error(ops, temporary_path, timeout_error)

      {:error, _reason} = error ->
        cleanup_then_error(ops, temporary_path, error)
    end
  end

  defp reconcile_proven_link_timeout(
         ops,
         temporary_path,
         path,
         normalized,
         max_bytes,
         timeout_error
       ) do
    case document_match(ops, path, normalized, max_bytes) do
      :exact ->
        case cleanup(ops, temporary_path) do
          :ok -> sync_after_promotion(ops, path, normalized, max_bytes)
          {:error, _reason} = error -> error
        end

      :different ->
        cleanup_then_error(ops, temporary_path, timeout_error)

      {:error, _reason} = error ->
        cleanup_then_error(ops, temporary_path, error)
    end
  end

  defp write_temporary(ops, device, contents) do
    write_result =
      with :ok <- phase(ops, :write, :write, [device, contents]),
           :ok <- phase(ops, :file_sync, :sync, [device]) do
        :ok
      end

    close_result = phase(ops, :close, :close, [device])

    case {write_result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, _reason} = error, _close_result} -> error
      {:ok, {:error, _reason} = error} -> error
    end
  end

  defp ensure_parent(path, ops),
    do: phase(ops, :mkdir, :mkdir_p, [Path.dirname(path)])

  defp open_temporary(path, ops), do: open_temporary(path, ops, 0)

  defp open_temporary(_path, _ops, @max_temp_attempts),
    do: phase_error(:open, :failure)

  defp open_temporary(path, ops, attempt) do
    temporary_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}.stage"
      )

    case phase(ops, :open, :exists?, [temporary_path]) do
      false -> acquire_temporary(path, temporary_path, ops, attempt)
      true -> open_temporary(path, ops, attempt + 1)
      {:error, _reason} = error -> error
    end
  end

  defp acquire_temporary(path, temporary_path, ops, attempt) do
    case phase(ops, :open, :open, [temporary_path]) do
      {:ok, device} -> {:ok, temporary_path, device}
      {:error, {:storage_phase, :open, :exists}} -> open_temporary(path, ops, attempt + 1)
      {:error, _reason} = error -> error
    end
  end

  defp sync_directory(ops, directory) do
    phase(ops, :directory_sync, :sync_dir, [directory])
  end

  defp sync_after_promotion(ops, path, normalized, max_bytes) do
    case sync_directory(ops, Path.dirname(path)) do
      :ok ->
        {:ok, path}

      {:error, {:storage_phase, :directory_sync, :timeout}} = timeout_error ->
        retry_directory_sync(ops, path, normalized, max_bytes, timeout_error)

      {:error, _reason} = error ->
        error
    end
  end

  defp retry_directory_sync(ops, path, normalized, max_bytes, timeout_error) do
    case document_match(ops, path, normalized, max_bytes) do
      :exact ->
        case sync_directory(ops, Path.dirname(path)) do
          :ok -> {:ok, path}
          {:error, _reason} = error -> error
        end

      :different ->
        timeout_error

      {:error, _reason} = error ->
        error
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
      :ok
    end
  end

  defp enforce_max_bytes(contents, max_bytes) when byte_size(contents) <= max_bytes, do: :ok
  defp enforce_max_bytes(_contents, _max_bytes), do: {:error, :eoverflow}

  defp document_match(ops, path, normalized, max_bytes) do
    case phase(ops, :read, :read, [path, max_bytes]) do
      {:ok, contents} when byte_size(contents) <= max_bytes ->
        if decode_object(contents) == {:ok, normalized}, do: :exact, else: :different

      {:ok, _oversized_contents} ->
        :different

      {:error, _reason} = error ->
        error
    end
  end

  defp phase(ops, phase, function, arguments) do
    ops
    |> call(function, arguments)
    |> validate_phase_result(function)
    |> sanitize_phase_result(phase)
  end

  defp validate_phase_result({:ok, contents} = result, :read) when is_binary(contents),
    do: result

  defp validate_phase_result(value, :exists?) when is_boolean(value), do: value
  defp validate_phase_result(value, :same_file?) when is_boolean(value), do: value
  defp validate_phase_result({:ok, _device} = result, :open), do: result

  defp validate_phase_result(:ok, function)
       when function in [:mkdir_p, :write, :sync, :close, :rename, :link, :rm, :sync_dir],
       do: :ok

  defp validate_phase_result({:error, _reason} = result, _function), do: result
  defp validate_phase_result(_result, _function), do: {:error, :malformed_file_ops_return}

  defp sanitize_phase_result({:error, :timeout}, phase), do: phase_error(phase, :timeout)

  defp sanitize_phase_result({:error, :enoent}, phase)
       when phase in [:read, :stage_cleanup],
       do: phase_error(phase, :not_found)

  defp sanitize_phase_result({:error, :eoverflow}, :read),
    do: phase_error(:read, :overflow)

  defp sanitize_phase_result({:error, :eexist}, phase) when phase in [:open, :link],
    do: phase_error(phase, :exists)

  defp sanitize_phase_result({:error, _reason}, phase), do: phase_error(phase, :failure)
  defp sanitize_phase_result(result, _phase), do: result

  @spec phase_error(phase(), :timeout | :not_found | :overflow | :exists | :failure) ::
          {:error, phase_error()}
  defp phase_error(phase, reason), do: {:error, {:storage_phase, phase, reason}}

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
    case phase(ops, :stage_cleanup, :rm, [path]) do
      :ok -> :ok
      {:error, {:storage_phase, :stage_cleanup, :not_found}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp cleanup_then_error(ops, temporary_path, original_error) do
    case cleanup(ops, temporary_path) do
      :ok -> original_error
      {:error, _reason} = cleanup_error -> cleanup_error
    end
  end

  defp not_found,
    do: {:error, %Error{code: :not_found, message: "storage document not found", details: %{}}}

  defp oversized,
    do:
      {:error,
       %Error{code: :invalid, message: "storage document exceeds size limit", details: %{}}}

  defp invalid,
    do: {:error, %Error{code: :invalid, message: "invalid storage document", details: %{}}}

  defp conflict,
    do: {:error, %Error{code: :conflict, message: "storage document conflicts", details: %{}}}

  defp timeout,
    do: {:error, %Error{code: :timeout, message: "storage operation timed out", details: %{}}}

  defp internal,
    do: {:error, %Error{code: :internal, message: "storage operation failed", details: %{}}}
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
  @callback same_file?(Path.t(), Path.t()) :: boolean() | {:error, term()}
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

  def same_file?(source, target) do
    with {:ok, source_stat} <- File.stat(source),
         {:ok, target_stat} <- File.stat(target) do
      source_stat.inode == target_stat.inode and
        source_stat.major_device == target_stat.major_device
    else
      {:error, :enoent} -> false
      {:error, reason} -> {:error, reason}
    end
  end

  def sync_dir(directory) do
    with {:ok, device} <- :file.open(directory, [:read, :raw, :directory]) do
      result =
        case :file.sync(device) do
          {:error, :enotsup} -> :ok
          other -> other
        end

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
