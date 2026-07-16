defmodule YellowDog.Management.Storage.AtomicJson do
  @moduledoc """
  Durable JSON reads plus immutable creation and atomic replacement.
  """

  alias YellowDog.Sync.Error

  @max_temp_attempts 32

  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec read(Path.t()) :: result(term())
  def read(path) when is_binary(path) do
    read(path, file_ops())
  end

  def read(_path), do: invalid()

  @doc false
  @spec read(Path.t(), module()) :: result(term())
  def read(path, ops) when is_binary(path) and is_atom(ops) do
    case ops.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> not_found()
      {:error, reason} -> file_error(reason)
    end
  rescue
    _exception -> invalid()
  end

  def read(_path, _ops), do: invalid()

  @doc false
  @spec ls(Path.t(), module()) :: {:ok, [String.t()]} | {:error, term()}
  def ls(path, ops) when is_binary(path) and is_atom(ops) do
    module =
      if Code.ensure_loaded?(ops) and function_exported?(ops, :ls, 1),
        do: ops,
        else: __MODULE__.FileOps

    module.ls(path)
  rescue
    _exception -> {:error, :list_exception}
  catch
    _kind, _reason -> {:error, :list_exit}
  end

  def ls(_path, _ops), do: {:error, :invalid_path}

  @spec create(Path.t(), term()) :: result(Path.t())
  def create(path, value) when is_binary(path) do
    ops = file_ops()

    with {:ok, contents} <- encode(value),
         :ok <- mkdir_parent(path, ops),
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

  @doc false
  @spec stage(Path.t(), term()) :: result(Path.t())
  def stage(path, value) when is_binary(path) do
    stage(path, value, staging_path(path))
  end

  def stage(_path, _value), do: invalid()

  @doc false
  @spec stage(Path.t(), term(), Path.t()) :: result(Path.t())
  def stage(path, value, staging_path)
      when is_binary(path) and is_binary(staging_path) do
    stage(path, value, staging_path, file_ops())
  end

  def stage(_path, _value, _staging_path), do: invalid()

  @doc false
  @spec stage(Path.t(), term(), Path.t(), module()) :: result(Path.t())
  def stage(path, value, staging_path, ops)
      when is_binary(path) and is_binary(staging_path) and is_atom(ops) do
    with true <- valid_staging_path?(path, staging_path),
         {:ok, contents} <- encode(value),
         :ok <- mkdir_parent(path, ops),
         {:ok, device} <- ops.open(staging_path) do
      case write_sync_close(ops, device, contents) do
        :ok -> {:ok, staging_path}
        {:error, reason} -> cleanup_path(ops, staging_path, reason)
      end
    else
      false -> invalid()
      {:error, %Error{}} = error -> error
      {:error, :eexist} -> conflict()
      {:error, reason} -> file_error(reason)
    end
  rescue
    _exception -> invalid()
  end

  def stage(_path, _value, _staging_path, _ops), do: invalid()

  @doc false
  @spec staging_path(Path.t()) :: Path.t()
  def staging_path(path) when is_binary(path) do
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{random_suffix()}.stage")
  end

  @doc false
  @spec owned((-> term()), integer()) :: term()
  def owned(operation, deadline) when is_function(operation, 0) and is_integer(deadline) do
    owner = self()
    token = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        send(owner, {:atomic_json_owned_result, token, run_owned(operation)})
      end)

    await_owned(worker, monitor, token, deadline)
  end

  def owned(_operation, _deadline), do: invalid()

  @doc false
  @spec promote(Path.t(), Path.t()) :: result(Path.t())
  def promote(staging_path, path)
      when is_binary(staging_path) and is_binary(path) do
    promote(staging_path, path, file_ops())
  end

  def promote(_staging_path, _path), do: invalid()

  @doc false
  @spec promote(Path.t(), Path.t(), module()) :: result(Path.t())
  def promote(staging_path, path, ops)
      when is_binary(staging_path) and is_binary(path) and is_atom(ops) do
    if Path.dirname(staging_path) == Path.dirname(path) and staging_path != path do
      result =
        try do
          case ops.link(staging_path, path) do
            :ok -> {:ok, path}
            {:error, :eexist} -> conflict()
            {:error, reason} -> file_error(reason)
          end
        rescue
          _exception -> file_error(:link_exception)
        catch
          _kind, _reason -> file_error(:link_exit)
        end

      best_effort_remove(ops, staging_path)
      result
    else
      invalid()
    end
  end

  def promote(_staging_path, _path, _ops), do: invalid()

  @spec replace(Path.t(), term()) :: result(Path.t())
  def replace(path, value) when is_binary(path) do
    replace(path, value, file_ops())
  end

  def replace(_path, _value), do: invalid()

  @doc false
  @spec replace(Path.t(), term(), module()) :: result(Path.t())
  def replace(path, value, ops) when is_binary(path) and is_atom(ops) do
    with {:ok, contents} <- encode(value),
         :ok <- mkdir_parent(path, ops),
         {:ok, temporary_path, device} <- open_temporary(path, ops) do
      replace_from_temporary(ops, temporary_path, device, contents, path)
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> file_error(reason)
    end
  rescue
    _exception -> invalid()
  end

  def replace(_path, _value, _ops), do: invalid()

  @doc false
  @spec replace(Path.t(), term(), Path.t(), module()) :: result(Path.t())
  def replace(path, value, staging_path, ops)
      when is_binary(path) and is_binary(staging_path) and is_atom(ops) do
    with {:ok, ^staging_path} <- stage(path, value, staging_path, ops) do
      replace_staged(path, staging_path, ops)
    end
  end

  def replace(_path, _value, _staging_path, _ops), do: invalid()

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> invalid()
    end
  end

  defp run_owned(operation) do
    operation.()
  rescue
    _exception -> file_error(:operation_exception)
  catch
    _kind, _reason -> file_error(:operation_exit)
  end

  defp await_owned(worker, monitor, token, deadline) do
    receive do
      {:atomic_json_owned_result, ^token, result} ->
        await_owned_down(worker, monitor, token)
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        take_owned_result(token)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Process.exit(worker, :kill)
        await_owned_down(worker, monitor, token)
        timeout()
    end
  end

  defp await_owned_down(worker, monitor, token) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> flush_owned_result(token)
      {:atomic_json_owned_result, ^token, _result} -> await_owned_down(worker, monitor, token)
    end
  end

  defp take_owned_result(token) do
    receive do
      {:atomic_json_owned_result, ^token, result} -> result
    after
      0 -> file_error(:operation_exit)
    end
  end

  defp flush_owned_result(token) do
    receive do
      {:atomic_json_owned_result, ^token, _result} -> flush_owned_result(token)
    after
      0 -> :ok
    end
  end

  defp encode(value) do
    case Jason.encode(value) do
      {:ok, contents} -> {:ok, contents}
      {:error, _reason} -> invalid()
    end
  end

  defp mkdir_parent(path, ops), do: ops.mkdir_p(Path.dirname(path))

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

  defp replace_staged(path, staging_path, ops) do
    if valid_staging_path?(path, staging_path) do
      result =
        try do
          case ops.rename(staging_path, path) do
            :ok -> {:ok, path}
            {:error, reason} -> cleanup_path(ops, staging_path, reason)
          end
        rescue
          _exception -> cleanup_path(ops, staging_path, :rename_exception)
        catch
          _kind, _reason -> cleanup_path(ops, staging_path, :rename_exit)
        end

      result
    else
      invalid()
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

  defp valid_staging_path?(path, staging_path) do
    Path.dirname(staging_path) == Path.dirname(path) and
      String.starts_with?(Path.basename(staging_path), ".#{Path.basename(path)}.") and
      String.ends_with?(staging_path, ".stage") and staging_path != path
  end

  if Mix.env() == :test do
    defp temporary_name(path) do
      case Application.get_env(:yellow_dog_management_core, :atomic_json_temp_name) do
        generator when is_function(generator, 1) -> generator.(path)
        _other -> ".#{Path.basename(path)}.#{random_suffix()}.tmp"
      end
    end

    defp file_ops do
      Application.get_env(
        :yellow_dog_management_core,
        :atomic_json_file_ops,
        YellowDog.Management.Storage.AtomicJson.FileOps
      )
    end
  else
    defp temporary_name(path), do: ".#{Path.basename(path)}.#{random_suffix()}.tmp"

    defp file_ops, do: YellowDog.Management.Storage.AtomicJson.FileOps
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(18)
    |> Base.url_encode64(padding: false)
  end

  defp not_found,
    do: {:error, Error.new(:not_found, "JSON document not found", %{})}

  defp conflict,
    do: {:error, Error.new(:conflict, "JSON document already exists", %{})}

  defp timeout,
    do: {:error, Error.new(:timeout, "JSON storage operation timed out", %{})}

  defp invalid,
    do: {:error, Error.new(:invalid, "invalid JSON document", %{})}

  defp file_error(reason) do
    {:error,
     Error.new(:internal, "JSON storage operation failed", %{"reason" => inspect(reason)})}
  end
end

defmodule YellowDog.Management.Storage.AtomicJson.FileOps do
  @moduledoc false

  def read(path), do: File.read(path)
  def ls(path), do: File.ls(path)
  def mkdir_p(path), do: File.mkdir_p(path)
  def open(path), do: :file.open(path, [:write, :exclusive, :binary, :raw])
  def write(device, contents), do: :file.write(device, contents)
  def sync(device), do: :file.sync(device)
  def close(device), do: :file.close(device)
  def rename(source, target), do: :file.rename(source, target)
  def link(source, target), do: :file.make_link(source, target)
  def rm(path), do: File.rm(path)
end
