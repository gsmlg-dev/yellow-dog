defmodule YellowDog.Netboot.Asset.StoreTestFileOps do
  @moduledoc false

  alias YellowDog.Netboot.ManagedStorage.FileOps

  def start_link(failures) when is_map(failures) do
    Agent.start_link(fn -> %{counts: %{}, failures: failures} end)
  end

  def read(path, agent), do: invoke(:read, [path], agent, fn -> FileOps.read(path, nil) end)
  def size(path, agent), do: invoke(:size, [path], agent, fn -> FileOps.size(path, nil) end)

  def mkdir_p(path, agent),
    do: invoke(:mkdir_p, [path], agent, fn -> FileOps.mkdir_p(path, nil) end)

  def open(path, agent), do: invoke(:open, [path], agent, fn -> FileOps.open(path, nil) end)

  def write(device, contents, agent),
    do: invoke(:write, [device, contents], agent, fn -> FileOps.write(device, contents, nil) end)

  def sync(device, agent),
    do: invoke(:sync, [device], agent, fn -> FileOps.sync(device, nil) end)

  def close(device, agent) do
    invoke(:close, [device], agent, fn -> FileOps.close(device, nil) end, close_on_failure: true)
  end

  def rename(source, target, agent),
    do:
      invoke({:rename, target}, [source, target], agent, fn ->
        FileOps.rename(source, target, nil)
      end)

  def rm(path, agent),
    do: invoke({:rm, path}, [path], agent, fn -> FileOps.rm(path, nil) end)

  defp invoke(key, _arguments, agent, fallback, opts \\ []) do
    fail? =
      Agent.get_and_update(agent, fn state ->
        count = Map.get(state.counts, key, 0) + 1
        failures = Map.get(state.failures, key, [])
        {count in failures, put_in(state, [:counts, key], count)}
      end)

    if fail? do
      if opts[:close_on_failure], do: fallback.()
      {:error, :injected}
    else
      fallback.()
    end
  end
end
