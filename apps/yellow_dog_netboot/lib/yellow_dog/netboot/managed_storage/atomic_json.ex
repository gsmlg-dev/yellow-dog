defmodule YellowDog.Netboot.ManagedStorage.AtomicJson do
  @moduledoc """
  Bounded JSON-object persistence for Netboot-managed sidecars.
  """

  alias YellowDog.Netboot.ManagedStorage.FileOps

  @default_max_bytes 1_048_576
  @max_temp_attempts 16

  @type error ::
          :invalid_input
          | :invalid_options
          | :read_failed
          | :invalid_json
          | :invalid_object
          | :too_large
          | :encode_failed
          | :mkdir_failed
          | :open_failed
          | :write_failed
          | :sync_failed
          | :close_failed
          | :rename_failed

  @type result(value) :: {:ok, value} | {:error, error()}

  @doc """
  Reads a JSON object, returning `default` when the sidecar does not exist.

  `:file_ops` accepts `{module, context}` for per-call filesystem injection.
  `:max_bytes` defaults to #{@default_max_bytes}.
  """
  @spec read(Path.t(), map(), keyword()) :: result(map())
  def read(path, default, opts \\ [])

  def read(path, default, opts) when is_binary(path) and is_map(default) do
    with true <- valid_path?(path),
         {:ok, ops} <- file_ops(opts),
         {:ok, max_bytes} <- max_bytes(opts) do
      read_file(path, default, ops, max_bytes)
    else
      false -> {:error, :invalid_input}
      {:error, :invalid_options} -> {:error, :invalid_options}
    end
  end

  def read(_path, _default, _opts), do: {:error, :invalid_input}

  @doc """
  Atomically replaces a sidecar with a JSON object.

  The temporary file is unique, created in the final file's directory, and is
  removed only by the caller that created it when a write phase fails.
  """
  @spec write(Path.t(), map(), keyword()) :: :ok | {:error, error()}
  def write(path, object, opts \\ [])

  def write(path, object, opts) when is_binary(path) and is_map(object) do
    with true <- valid_path?(path),
         {:ok, ops} <- file_ops(opts),
         {:ok, contents} <- encode(object),
         :ok <- mkdir_parent(path, ops),
         {:ok, temporary_path, device} <- open_temporary(path, ops) do
      write_temporary(ops, temporary_path, device, contents, path)
    else
      false -> {:error, :invalid_input}
      {:error, :invalid_options} -> {:error, :invalid_options}
      {:error, :encode_failed} -> {:error, :encode_failed}
      {:error, :mkdir_failed} -> {:error, :mkdir_failed}
      {:error, :open_failed} -> {:error, :open_failed}
    end
  end

  def write(_path, _object, _opts), do: {:error, :invalid_input}

  defp read_file(path, default, ops, max_bytes) do
    case call(ops, :size, [path]) do
      {:ok, size} when is_integer(size) and size >= 0 and size <= max_bytes ->
        decode_file(path, default, ops)

      {:ok, size} when is_integer(size) and size > max_bytes ->
        {:error, :too_large}

      {:error, :enoent} ->
        {:ok, default}

      _other ->
        {:error, :read_failed}
    end
  end

  defp decode_file(path, default, ops) do
    case call(ops, :read, [path]) do
      {:ok, contents} when is_binary(contents) -> decode(contents)
      {:error, :enoent} -> {:ok, default}
      _other -> {:error, :read_failed}
    end
  end

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :invalid_object}
      {:error, _reason} -> {:error, :invalid_json}
    end
  rescue
    _exception -> {:error, :invalid_json}
  end

  defp encode(object) do
    case Jason.encode(object) do
      {:ok, contents} -> {:ok, contents}
      {:error, _reason} -> {:error, :encode_failed}
    end
  rescue
    _exception -> {:error, :encode_failed}
  end

  defp mkdir_parent(path, ops) do
    case call(ops, :mkdir_p, [Path.dirname(path)]) do
      :ok -> :ok
      _other -> {:error, :mkdir_failed}
    end
  end

  defp open_temporary(path, ops, attempt \\ 0)

  defp open_temporary(_path, _ops, @max_temp_attempts), do: {:error, :open_failed}

  defp open_temporary(path, ops, attempt) do
    temporary_path = temporary_path(path)

    case call(ops, :open, [temporary_path]) do
      {:ok, device} -> {:ok, temporary_path, device}
      {:error, :eexist} -> open_temporary(path, ops, attempt + 1)
      _other -> {:error, :open_failed}
    end
  end

  defp write_temporary(ops, temporary_path, device, contents, path) do
    case write_sync_close(ops, device, contents) do
      :ok ->
        case call(ops, :rename, [temporary_path, path]) do
          :ok -> :ok
          _other -> cleanup_temporary(ops, temporary_path, :rename_failed)
        end

      {:error, reason} ->
        cleanup_temporary(ops, temporary_path, reason)
    end
  end

  defp write_sync_close(ops, device, contents) do
    write_result =
      case call(ops, :write, [device, contents]) do
        :ok ->
          case call(ops, :sync, [device]) do
            :ok -> :ok
            _other -> {:error, :sync_failed}
          end

        _other ->
          {:error, :write_failed}
      end

    close_result = close_device(ops, device)

    case {write_result, close_result} do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {{:error, reason}, _close_result} -> {:error, reason}
    end
  end

  defp close_device(ops, device) do
    case call(ops, :close, [device]) do
      :ok ->
        :ok

      _other ->
        best_effort_close(ops, device)
        {:error, :close_failed}
    end
  end

  defp cleanup_temporary(ops, temporary_path, reason) do
    _ = call(ops, :rm, [temporary_path])
    {:error, reason}
  end

  defp best_effort_close(ops, device) do
    _ = call(ops, :close, [device])
    :ok
  end

  defp temporary_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{suffix}.tmp")
  end

  defp valid_path?(path), do: path != "" and not String.contains?(path, <<0>>)

  defp file_ops(opts) when is_list(opts) do
    case Keyword.get(opts, :file_ops, {FileOps, nil}) do
      {module, context} when is_atom(module) -> {:ok, {module, context}}
      _other -> {:error, :invalid_options}
    end
  end

  defp file_ops(_opts), do: {:error, :invalid_options}

  defp max_bytes(opts) when is_list(opts) do
    case Keyword.get(opts, :max_bytes, @default_max_bytes) do
      size when is_integer(size) and size > 0 -> {:ok, size}
      _other -> {:error, :invalid_options}
    end
  end

  defp max_bytes(_opts), do: {:error, :invalid_options}

  defp call({module, context}, operation, arguments) do
    if Code.ensure_loaded?(module) and
         function_exported?(module, operation, length(arguments) + 1) do
      apply(module, operation, arguments ++ [context])
    else
      {:error, :unsupported_file_ops}
    end
  rescue
    _exception -> {:error, :file_ops_exception}
  catch
    _kind, _reason -> {:error, :file_ops_exit}
  end
end
