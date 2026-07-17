defmodule YellowDog.ServerAgent.CommandJournalTestClock do
  def start_link(values), do: Agent.start_link(fn -> values end)

  def now(clock) do
    Agent.get_and_update(clock, fn
      [value | rest] -> {value, rest}
      [] -> {~U[2026-07-17 00:00:00Z], []}
    end)
  end
end

defmodule YellowDog.ServerAgent.CommandJournalTestFileOps do
  alias YellowDog.ServerAgent.Storage.FileOps

  @failure_key {__MODULE__, :failure}

  def fail_next(phase, reason \\ :eio),
    do: :persistent_term.put(@failure_key, [{:before, phase, reason}])

  def fail_times(phase, reason, count) when is_integer(count) and count > 0 do
    :persistent_term.put(@failure_key, List.duplicate({:before, phase, reason}, count))
  end

  def fail_after(phase, callback, reason \\ :eio) when is_function(callback, 0),
    do: :persistent_term.put(@failure_key, [{:after, phase, reason, callback}])

  def run_after(phase, callback) when is_function(callback, 0),
    do: :persistent_term.put(@failure_key, [{:after_success, phase, callback}])

  def run_after_return(phase, callback) when is_function(callback, 0),
    do: :persistent_term.put(@failure_key, [{:after_return, phase, callback}])

  def clear, do: :persistent_term.erase(@failure_key)

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
    case take_failure(phase) do
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

      {:after_success, callback} ->
        case operation.() do
          :ok ->
            callback.()
            :ok

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

  defp take_failure(phase) do
    case :persistent_term.get(@failure_key, []) do
      [{:before, ^phase, reason} | rest] ->
        store_failures(rest)
        {:before, reason}

      [{:after, ^phase, reason, callback} | rest] ->
        store_failures(rest)
        {:after, reason, callback}

      [{:after_success, ^phase, callback} | rest] ->
        store_failures(rest)
        {:after_success, callback}

      [{:after_return, ^phase, callback} | rest] ->
        store_failures(rest)
        {:after_return, callback}

      _other ->
        :none
    end
  end

  defp store_failures([]), do: clear()

  defp store_failures(failures) do
    :persistent_term.put(@failure_key, failures)
  end
end

defmodule YellowDog.ServerAgent.CommandJournalFailingScanner do
  def scan(_directory), do: {:error, :eacces}
end

defmodule YellowDog.ServerAgent.CommandJournalTraversalScanner do
  def scan(_directory), do: {:ok, [%{name: "../escape.json", type: :regular}]}
end

defmodule YellowDog.ServerAgent.CommandJournalSwapAfterScanScanner do
  alias YellowDog.ServerAgent.CommandJournal.DirectoryScanner

  @callback_key {__MODULE__, :callback}

  def run_after_scan(callback) when is_function(callback, 0),
    do: :persistent_term.put(@callback_key, callback)

  def clear, do: :persistent_term.erase(@callback_key)

  def scan(directory) do
    case DirectoryScanner.scan(directory) do
      {:ok, entries} ->
        callback = :persistent_term.get(@callback_key)
        clear()
        callback.()
        {:ok, entries}

      error ->
        error
    end
  end
end
