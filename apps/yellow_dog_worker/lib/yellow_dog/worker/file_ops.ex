defmodule YellowDog.Worker.FileOps do
  @moduledoc false

  # Linux syncfs(2) via coreutils makes directory metadata durable. Unlike an
  # unchecked rename, its failure is returned to the caller.
  def sync_path(path) do
    case System.cmd("sync", ["-f", path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {message, status} -> {:error, {:sync_failed, status, message}}
    end
  rescue
    error -> {:error, {:sync_failed, error}}
  end

  def write_synced(path, bytes, backend \\ :file) do
    write(path, bytes, backend, nil)
  end

  def write_private_synced(path, bytes), do: write(path, bytes, :file, 0o600)

  defp write(path, bytes, backend, mode) do
    with {:ok, file} <- backend.open(path, [:write, :binary, :exclusive, :raw]) do
      result =
        with :ok <- if(mode, do: File.chmod(path, mode), else: :ok),
             :ok <- backend.write(file, bytes),
             :ok <- backend.sync(file) do
          :ok
        end

      close = backend.close(file)

      case {result, close} do
        {:ok, :ok} -> :ok
        {{:error, reason}, _} -> {:error, reason}
        {_, {:error, reason}} -> {:error, reason}
      end
    end
  end

  def rename(source, target), do: File.rename(source, target)
  def read(path), do: File.read(path)
  def remove(path), do: File.rm(path)
end
