defmodule YellowDog.ServerAgent.TestStorageFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  @key {__MODULE__, :failure}
  @capture_key {__MODULE__, :capture_open_to}
  @call_capture_key {__MODULE__, :capture_calls_to}
  @return_key {__MODULE__, :returns}
  @after_return_key {__MODULE__, :after_returns}
  @crash_key {__MODULE__, :crashes}

  def fail_at(phase), do: Process.put(@key, phase)
  def clear_failure, do: Process.delete(@key)
  def capture_open_to(pid) when is_pid(pid), do: Process.put(@capture_key, pid)
  def clear_capture, do: Process.delete(@capture_key)
  def capture_calls_to(pid) when is_pid(pid), do: Process.put(@call_capture_key, pid)
  def clear_call_capture, do: Process.delete(@call_capture_key)
  def return_at(phase, value), do: Process.put(@return_key, %{phase => value})

  def return_sequence_at(phase, values) do
    Process.put(@return_key, Map.put(Process.get(@return_key, %{}), phase, values))
  end

  def clear_returns, do: Process.delete(@return_key)
  def return_after_at(phase, value), do: Process.put(@after_return_key, %{phase => value})
  def clear_after_returns, do: Process.delete(@after_return_key)
  def crash_at(phase, crash), do: Process.put(@crash_key, %{phase => crash})
  def clear_crashes, do: Process.delete(@crash_key)

  def read(path, max_bytes), do: invoke(:read, fn -> FileOps.read(path, max_bytes) end)
  def mkdir_p(path), do: invoke(:mkdir_p, fn -> FileOps.mkdir_p(path) end)
  def exists?(path), do: invoke(:exists?, fn -> FileOps.exists?(path) end)

  def open(path) do
    capture_open(path)
    invoke(:open, fn -> FileOps.open(path) end)
  end

  def write(device, contents), do: invoke(:write, fn -> FileOps.write(device, contents) end)
  def sync(device), do: invoke(:sync, fn -> FileOps.sync(device) end)
  def close(device), do: invoke(:close, fn -> FileOps.close(device) end)

  def rename(source, target) do
    invoke(:rename, fn -> FileOps.rename(source, target) end)
  end

  def link(source, target) do
    invoke(:link, fn -> FileOps.link(source, target) end)
  end

  def rm(path), do: invoke(:rm, fn -> FileOps.rm(path) end)

  def same_file?(source, target) do
    invoke(:same_file, fn -> FileOps.same_file?(source, target) end)
  end

  def sync_dir(path), do: invoke(:sync_dir, fn -> FileOps.sync_dir(path) end)

  defp invoke(phase, operation) do
    capture_call(phase)
    maybe_crash(phase)

    case configured_return(phase) do
      {:ok, :delegate} -> operation.()
      {:ok, value} -> value
      :none -> invoke_default(phase, operation)
    end
  end

  defp invoke_default(phase, operation) do
    if Process.get(@key) == phase do
      {:error, :eio}
    else
      result = operation.()

      case Process.get(@after_return_key, %{}) do
        %{^phase => value} -> value
        _returns -> result
      end
    end
  end

  defp configured_return(phase) do
    returns = Process.get(@return_key, %{})

    case Map.fetch(returns, phase) do
      {:ok, [value | remaining]} ->
        Process.put(@return_key, update_sequence(returns, phase, remaining))
        {:ok, value}

      {:ok, []} ->
        Process.put(@return_key, Map.delete(returns, phase))
        :none

      :error ->
        :none

      {:ok, value} ->
        {:ok, value}
    end
  end

  defp update_sequence(returns, phase, []), do: Map.delete(returns, phase)
  defp update_sequence(returns, phase, remaining), do: Map.put(returns, phase, remaining)

  defp maybe_crash(phase) do
    case Process.get(@crash_key, %{}) do
      %{^phase => {:raise, message}} -> raise message
      %{^phase => {:throw, reason}} -> throw(reason)
      %{^phase => {:exit, reason}} -> exit(reason)
      _crashes -> :ok
    end
  end

  defp capture_call(phase) do
    case Process.get(@call_capture_key) do
      pid when is_pid(pid) -> send(pid, {:storage_file_op, phase})
      _other -> :ok
    end
  end

  defp capture_open(path) do
    case Process.get(@capture_key) do
      pid when is_pid(pid) -> send(pid, {:storage_opened, path})
      _other -> :ok
    end
  end
end

defmodule YellowDog.ServerAgent.OversizedSuccessFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  def read(_path, _max_bytes), do: {:ok, ~s({"value":"oversized"})}
  defdelegate mkdir_p(path), to: FileOps
  defdelegate exists?(path), to: FileOps
  defdelegate open(path), to: FileOps
  defdelegate write(device, contents), to: FileOps
  defdelegate sync(device), to: FileOps
  defdelegate close(device), to: FileOps
  defdelegate rename(source, target), to: FileOps
  defdelegate link(source, target), to: FileOps
  defdelegate rm(path), to: FileOps
  defdelegate same_file?(source, target), to: FileOps
  defdelegate sync_dir(path), to: FileOps
end

defmodule YellowDog.ServerAgent.ForeignStageRaceFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  @owner_key {__MODULE__, :owner}
  @raced_key {__MODULE__, :raced}

  def arm(owner) when is_pid(owner) do
    Process.put(@owner_key, owner)
    Process.put(@raced_key, false)
  end

  def clear do
    Process.delete(@owner_key)
    Process.delete(@raced_key)
  end

  defdelegate read(path, max_bytes), to: FileOps
  defdelegate mkdir_p(path), to: FileOps
  def exists?(_path), do: false

  def open(path) do
    if Process.get(@raced_key, false) do
      FileOps.open(path)
    else
      Process.put(@raced_key, true)
      :ok = File.write(path, "foreign-stage", [:exclusive])
      send(Process.get(@owner_key), {:foreign_stage, path})
      {:error, :eexist}
    end
  end

  defdelegate write(device, contents), to: FileOps
  defdelegate sync(device), to: FileOps
  defdelegate close(device), to: FileOps
  defdelegate rename(source, target), to: FileOps
  defdelegate link(source, target), to: FileOps
  defdelegate rm(path), to: FileOps
  defdelegate same_file?(source, target), to: FileOps
  defdelegate sync_dir(path), to: FileOps
end

defmodule YellowDog.ServerAgent.TimeoutBeforeRenameFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  def read(path, max_bytes), do: FileOps.read(path, max_bytes)
  def mkdir_p(path), do: FileOps.mkdir_p(path)
  def exists?(path), do: FileOps.exists?(path)
  def open(path), do: FileOps.open(path)
  def write(device, contents), do: FileOps.write(device, contents)
  def sync(device), do: FileOps.sync(device)
  def close(device), do: FileOps.close(device)

  def rename(_source, _target) do
    send(Process.whereis(:yellow_dog_server_agent_storage_timeout_test), :rename_started)
    {:error, :timeout}
  end

  def link(source, target), do: FileOps.link(source, target)
  def rm(path), do: FileOps.rm(path)
  def same_file?(source, target), do: FileOps.same_file?(source, target)
  def sync_dir(path), do: FileOps.sync_dir(path)
end

defmodule YellowDog.ServerAgent.TimeoutDuringSyncDirFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  def read(path, max_bytes) do
    send(Process.whereis(:yellow_dog_server_agent_storage_timeout_test), :reconcile_read)
    FileOps.read(path, max_bytes)
  end

  defdelegate mkdir_p(path), to: FileOps
  defdelegate exists?(path), to: FileOps
  defdelegate open(path), to: FileOps
  defdelegate write(device, contents), to: FileOps
  defdelegate sync(device), to: FileOps
  defdelegate close(device), to: FileOps
  defdelegate rename(source, target), to: FileOps
  defdelegate link(source, target), to: FileOps
  defdelegate rm(path), to: FileOps
  defdelegate same_file?(source, target), to: FileOps

  def sync_dir(_path) do
    send(Process.whereis(:yellow_dog_server_agent_storage_timeout_test), :sync_dir_started)
    {:error, :timeout}
  end
end

defmodule YellowDog.ServerAgent.AmbiguousRenameFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  def read(path, max_bytes) do
    send(Process.whereis(:yellow_dog_server_agent_storage_timeout_test), :reconcile_read)
    FileOps.read(path, max_bytes)
  end

  defdelegate mkdir_p(path), to: FileOps
  defdelegate exists?(path), to: FileOps
  defdelegate open(path), to: FileOps
  defdelegate write(device, contents), to: FileOps
  defdelegate sync(device), to: FileOps
  defdelegate close(device), to: FileOps

  def rename(source, target) do
    :ok = FileOps.rename(source, target)
    {:error, :timeout}
  end

  defdelegate link(source, target), to: FileOps
  defdelegate rm(path), to: FileOps
  defdelegate same_file?(source, target), to: FileOps
  defdelegate sync_dir(path), to: FileOps
end

defmodule YellowDog.ServerAgent.MissingSyncDirFileOps do
  alias YellowDog.ServerAgent.Storage.FileOps

  defdelegate read(path, max_bytes), to: FileOps
  defdelegate mkdir_p(path), to: FileOps
  defdelegate exists?(path), to: FileOps
  defdelegate open(path), to: FileOps
  defdelegate write(device, contents), to: FileOps
  defdelegate sync(device), to: FileOps
  defdelegate close(device), to: FileOps
  defdelegate rename(source, target), to: FileOps
  defdelegate link(source, target), to: FileOps
  defdelegate rm(path), to: FileOps
  defdelegate same_file?(source, target), to: FileOps
end

defmodule YellowDog.ServerAgent.JsonEncodableStruct do
  defstruct [:value]
end
