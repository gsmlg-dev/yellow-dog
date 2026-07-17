defmodule YellowDog.Netboot.ManagedStorage.TestFileOps do
  @moduledoc false

  alias YellowDog.Netboot.ManagedStorage.FileOps

  def read(path, context), do: invoke(:read, [path], context, fn -> FileOps.read(path, nil) end)
  def size(path, context), do: invoke(:size, [path], context, fn -> FileOps.size(path, nil) end)

  def mkdir_p(path, context),
    do: invoke(:mkdir_p, [path], context, fn -> FileOps.mkdir_p(path, nil) end)

  def open(path, context), do: invoke(:open, [path], context, fn -> FileOps.open(path, nil) end)

  def write(device, contents, context),
    do:
      invoke(:write, [device, contents], context, fn -> FileOps.write(device, contents, nil) end)

  def sync(device, context),
    do: invoke(:sync, [device], context, fn -> FileOps.sync(device, nil) end)

  def close(device, context),
    do: invoke(:close, [device], context, fn -> FileOps.close(device, nil) end)

  def rename(source, target, context),
    do: invoke(:rename, [source, target], context, fn -> FileOps.rename(source, target, nil) end)

  def rm(path, context), do: invoke(:rm, [path], context, fn -> FileOps.rm(path, nil) end)

  defp invoke(operation, arguments, context, fallback) do
    if owner = context[:owner] do
      send(owner, {:managed_storage_file_op, operation, arguments})
    end

    case context[:fail] do
      ^operation when operation == :close ->
        _ = fallback.()
        {:error, :injected}

      ^operation ->
        {:error, :injected}

      _other ->
        fallback.()
    end
  end
end
