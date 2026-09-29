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

  def write_synced(path, bytes) do
    with {:ok, file} <- :file.open(path, [:write, :binary, :exclusive, :raw]) do
      result =
        with :ok <- :file.write(file, bytes),
             :ok <- :file.sync(file) do
          :ok
        end

      close = :file.close(file)

      case {result, close} do
        {:ok, :ok} -> :ok
        {{:error, reason}, _} -> {:error, reason}
        {_, {:error, reason}} -> {:error, reason}
      end
    end
  end

  def rename(source, target), do: File.rename(source, target)
end
