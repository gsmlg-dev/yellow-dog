defmodule YellowDog.Netboot.Asset.StoreTestIndexOps do
  @moduledoc false

  alias YellowDog.Netboot.TFTP.FileIndex

  def start_link(failures) when is_map(failures) do
    Agent.start_link(fn -> %{counts: %{}, failures: failures} end)
  end

  def fail_next(agent, key) do
    Agent.update(agent, fn state ->
      next_count = Map.get(state.counts, key, 0) + 1

      update_in(state, [:failures, key], fn failures ->
        [next_count | failures || []]
      end)
    end)
  end

  def init(_agent), do: FileIndex.init()
  def snapshot(_agent), do: FileIndex.snapshot()

  def build_snapshot(root, opts, agent) do
    if fail?(agent, :build_snapshot) do
      {:error, :injected}
    else
      FileIndex.build_snapshot(root, opts)
    end
  end

  def replace(snapshot, agent) do
    if fail?(agent, :replace) do
      {:error, :injected}
    else
      FileIndex.replace(snapshot)
    end
  end

  defp fail?(agent, key) do
    Agent.get_and_update(agent, fn state ->
      count = Map.get(state.counts, key, 0) + 1
      failures = Map.get(state.failures, key, [])
      {count in failures, put_in(state, [:counts, key], count)}
    end)
  end
end
