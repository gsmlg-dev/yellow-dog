defmodule YellowDog.ServerAgent.TestStorageFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  @key {__MODULE__, :failure}
  @capture_key {__MODULE__, :capture_open_to}
  @return_key {__MODULE__, :returns}

  def fail_at(phase), do: Process.put(@key, phase)
  def clear_failure, do: Process.delete(@key)
  def capture_open_to(pid) when is_pid(pid), do: Process.put(@capture_key, pid)
  def clear_capture, do: Process.delete(@capture_key)
  def return_at(phase, value), do: Process.put(@return_key, %{phase => value})
  def clear_returns, do: Process.delete(@return_key)

  def read(path, max_bytes), do: maybe_return(:read, fn -> FileOps.read(path, max_bytes) end)
  def mkdir_p(path), do: maybe_fail(:mkdir_p, fn -> FileOps.mkdir_p(path) end)
  def exists?(path), do: maybe_return(:exists?, fn -> FileOps.exists?(path) end)

  def open(path) do
    capture_open(path)
    maybe_fail(:open, fn -> FileOps.open(path) end)
  end

  def write(device, contents) do
    maybe_fail(:write, fn -> FileOps.write(device, contents) end)
  end

  def sync(device) do
    maybe_fail(:sync, fn -> FileOps.sync(device) end)
  end

  def close(device) do
    result = FileOps.close(device)

    maybe_return(:close, fn ->
      if failure?(:close), do: {:error, :eio}, else: result
    end)
  end

  def rename(source, target) do
    maybe_fail(:rename, fn -> FileOps.rename(source, target) end)
  end

  def link(source, target) do
    maybe_fail(:link, fn -> FileOps.link(source, target) end)
  end

  def rm(path), do: maybe_return(:rm, fn -> FileOps.rm(path) end)

  def sync_dir(path) do
    maybe_fail(:sync_dir, fn -> FileOps.sync_dir(path) end)
  end

  defp maybe_fail(phase, operation) do
    maybe_return(phase, fn ->
      if failure?(phase), do: {:error, :eio}, else: operation.()
    end)
  end

  defp failure?(phase), do: Process.get(@key) == phase

  defp maybe_return(phase, operation) do
    case Process.get(@return_key, %{}) do
      %{^phase => value} -> value
      _returns -> operation.()
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
  defdelegate sync_dir(path), to: FileOps
end

defmodule YellowDog.ServerAgent.JsonEncodableStruct do
  defstruct [:value]
end
