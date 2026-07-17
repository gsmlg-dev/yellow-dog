defmodule YellowDog.ServerAgent.ConfigApplyStoreTestClock do
  def start_link(values), do: Agent.start_link(fn -> values end)

  def now(clock) do
    Agent.get_and_update(clock, fn
      [value | rest] -> {value, rest}
      [] -> {~U[2026-07-17 09:59:59Z], []}
    end)
  end
end

defmodule YellowDog.ServerAgent.ConfigApplyStoreTestFileOps do
  alias YellowDog.ServerAgent.Storage.FileOps

  @actions_key {__MODULE__, :actions}

  def fail_next(phase, reason \\ :eio),
    do: :persistent_term.put(@actions_key, [{:before, phase, reason}])

  def fail_after(phase, callback, reason \\ :eio) when is_function(callback, 0),
    do: :persistent_term.put(@actions_key, [{:after, phase, reason, callback}])

  def run_after_return(phase, callback) when is_function(callback, 0),
    do: :persistent_term.put(@actions_key, [{:after_return, phase, callback}])

  def clear, do: :persistent_term.erase(@actions_key)

  def read(path, max_bytes), do: invoke(:read, fn -> FileOps.read(path, max_bytes) end)
  def mkdir_p(path), do: invoke(:mkdir_p, fn -> FileOps.mkdir_p(path) end)
  def exists?(path), do: invoke(:exists?, fn -> FileOps.exists?(path) end)
  def open(path), do: invoke(:open, fn -> FileOps.open(path) end)
  def write(device, contents), do: invoke(:write, fn -> FileOps.write(device, contents) end)
  def sync(device), do: invoke(:sync, fn -> FileOps.sync(device) end)
  def close(device), do: invoke(:close, fn -> FileOps.close(device) end)
  def rename(source, target), do: invoke(:rename, fn -> FileOps.rename(source, target) end)
  def link(source, target), do: invoke(:link, fn -> FileOps.link(source, target) end)
  def rm(path), do: invoke(:rm, fn -> FileOps.rm(path) end)

  def same_file?(source, target),
    do: invoke(:same_file?, fn -> FileOps.same_file?(source, target) end)

  def sync_dir(path), do: invoke(:sync_dir, fn -> FileOps.sync_dir(path) end)

  defp invoke(phase, operation) do
    case take_action(phase) do
      {:before, reason} ->
        {:error, reason}

      {:after, reason, callback} ->
        case operation.() do
          :ok ->
            callback.()
            {:error, reason}

          error ->
            error
        end

      {:after_return, callback} ->
        result = operation.()
        callback.()
        result

      :none ->
        operation.()
    end
  end

  defp take_action(phase) do
    case :persistent_term.get(@actions_key, []) do
      [{:before, ^phase, reason} | rest] ->
        store_actions(rest)
        {:before, reason}

      [{:after, ^phase, reason, callback} | rest] ->
        store_actions(rest)
        {:after, reason, callback}

      [{:after_return, ^phase, callback} | rest] ->
        store_actions(rest)
        {:after_return, callback}

      _other ->
        :none
    end
  end

  defp store_actions([]), do: clear()
  defp store_actions(actions), do: :persistent_term.put(@actions_key, actions)
end
