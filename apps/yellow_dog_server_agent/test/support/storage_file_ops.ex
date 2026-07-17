defmodule YellowDog.ServerAgent.TestStorageFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  @key {__MODULE__, :failure}
  @capture_key {__MODULE__, :capture_open_to}

  def fail_at(phase), do: Process.put(@key, phase)
  def clear_failure, do: Process.delete(@key)
  def capture_open_to(pid) when is_pid(pid), do: Process.put(@capture_key, pid)
  def clear_capture, do: Process.delete(@capture_key)

  def read(path, max_bytes), do: FileOps.read(path, max_bytes)
  def mkdir_p(path), do: maybe_fail(:mkdir_p, fn -> FileOps.mkdir_p(path) end)
  def exists?(path), do: FileOps.exists?(path)

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
    if failure?(:close), do: {:error, :eio}, else: result
  end

  def rename(source, target) do
    maybe_fail(:rename, fn -> FileOps.rename(source, target) end)
  end

  def link(source, target) do
    maybe_fail(:link, fn -> FileOps.link(source, target) end)
  end

  def rm(path), do: FileOps.rm(path)

  def sync_dir(path) do
    maybe_fail(:sync_dir, fn -> FileOps.sync_dir(path) end)
  end

  defp maybe_fail(phase, operation) do
    if failure?(phase), do: {:error, :eio}, else: operation.()
  end

  defp failure?(phase), do: Process.get(@key) == phase

  defp capture_open(path) do
    case Process.get(@capture_key) do
      pid when is_pid(pid) -> send(pid, {:storage_opened, path})
      _other -> :ok
    end
  end
end

defmodule YellowDog.ServerAgent.TimeoutAfterRenameFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  def read(path, max_bytes), do: FileOps.read(path, max_bytes)
  def mkdir_p(path), do: FileOps.mkdir_p(path)
  def exists?(path), do: FileOps.exists?(path)
  def open(path), do: FileOps.open(path)
  def write(device, contents), do: FileOps.write(device, contents)
  def sync(device), do: FileOps.sync(device)
  def close(device), do: FileOps.close(device)

  def rename(source, target) do
    result = FileOps.rename(source, target)
    send(Process.whereis(:yellow_dog_server_agent_storage_timeout_test), :rename_called)
    Process.sleep(50)
    result
  end

  def link(source, target), do: FileOps.link(source, target)
  def rm(path), do: FileOps.rm(path)
  def sync_dir(path), do: FileOps.sync_dir(path)
end
