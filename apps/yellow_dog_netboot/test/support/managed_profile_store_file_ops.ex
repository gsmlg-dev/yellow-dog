defmodule YellowDog.Netboot.Manifest.ManagedProfileStoreFileOps do
  @moduledoc false

  alias YellowDog.Netboot.ManagedStorage.FileOps

  def read(path, context), do: call(:read, [path], context, fn -> FileOps.read(path, nil) end)
  def size(path, context), do: call(:size, [path], context, fn -> FileOps.size(path, nil) end)

  def mkdir_p(path, context),
    do: call(:mkdir_p, [path], context, fn -> FileOps.mkdir_p(path, nil) end)

  def open(path, context), do: call(:open, [path], context, fn -> FileOps.open(path, nil) end)

  def write(device, contents, context),
    do: call(:write, [device, contents], context, fn -> FileOps.write(device, contents, nil) end)

  def sync(device, context),
    do: call(:sync, [device], context, fn -> FileOps.sync(device, nil) end)

  def close(device, context),
    do: call(:close, [device], context, fn -> FileOps.close(device, nil) end)

  def rename(source, target, context),
    do: call(:rename, [source, target], context, fn -> FileOps.rename(source, target, nil) end)

  def rm(path, context), do: call(:rm, [path], context, fn -> FileOps.rm(path, nil) end)

  defp call(operation, arguments, context, fallback) do
    case context[:response] do
      response when is_function(response, 2) ->
        case response.(operation, arguments) do
          :pass -> fallback.()
          result -> result
        end

      _other ->
        fallback.()
    end
  end
end
