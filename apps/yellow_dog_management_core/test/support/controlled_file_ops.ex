defmodule YellowDog.Management.ControlledFileOps do
  @moduledoc false

  alias YellowDog.Management.Storage.AtomicJson.FileOps

  def read(path), do: invoke(:read, [path], fn -> FileOps.read(path) end)
  def ls(path), do: invoke(:ls, [path], fn -> FileOps.ls(path) end)
  def mkdir_p(path), do: invoke(:mkdir_p, [path], fn -> FileOps.mkdir_p(path) end)
  def open(path), do: invoke(:open, [path], fn -> FileOps.open(path) end)

  def write(device, contents),
    do: invoke(:write, [device, contents], fn -> FileOps.write(device, contents) end)

  def sync(device), do: invoke(:sync, [device], fn -> FileOps.sync(device) end)
  def close(device), do: invoke(:close, [device], fn -> FileOps.close(device) end)

  def rename(source, target),
    do: invoke(:rename, [source, target], fn -> FileOps.rename(source, target) end)

  def link(source, target),
    do: invoke(:link, [source, target], fn -> FileOps.link(source, target) end)

  def rm(path), do: invoke(:rm, [path], fn -> FileOps.rm(path) end)

  defp invoke(operation, arguments, fallback) do
    case Application.get_env(:yellow_dog_management_core, :management_test_file_ops_hook) do
      hook when is_function(hook, 2) ->
        case hook.(operation, arguments) do
          :ok -> fallback.()
          {:error, _reason} = error -> error
        end

      _other ->
        fallback.()
    end
  end
end
