defmodule YellowDog.Worker.TransitionCrashOps do
  alias YellowDog.Worker.{FileOps, TransitionJournal}

  def arm(boundary, fifo) do
    :persistent_term.put(__MODULE__, {boundary, fifo})
    manager = Process.whereis(YellowDog.Worker.ServiceManager)
    state = :sys.get_state(manager)
    :sys.replace_state(state.store, &%{&1 | ops: __MODULE__})

    if boundary == "during_action" do
      controller = state.controllers["dns-primary"]
      runtime = YellowDog.Worker.ServiceController.status(controller).runtime_pid
      :sys.suspend(runtime)
      tracer = spawn(fn -> trace_action(runtime) end)
      :erlang.trace_pattern({GenServer, :call, 3}, true, [:local])
      :erlang.trace(controller, true, [:call, {:tracer, tracer}])
    end

    :ok
  end

  def write_synced(path, bytes) do
    case TransitionJournal.decode(bytes) do
      {:ok, record} ->
        Process.put(:journal_record, record)
        last = List.last(record["actions"])

        if last && last["operation"] == "apply" && last["status"] == "accepted",
          do: barrier("after_action")

        if record["phase"] == "complete", do: barrier("finalization")

      _ ->
        :ok
    end

    FileOps.write_synced(path, bytes)
  end

  def rename(source, target) do
    result = FileOps.rename(source, target)

    if result == :ok and Path.basename(target) == "current" do
      Process.put(:pointer_renamed, true)
      barrier("pointer_rename")
    end

    result
  end

  def read(path), do: FileOps.read(path)
  def remove(path), do: FileOps.remove(path)

  def sync_path(path) do
    result = FileOps.sync_path(path)

    if result == :ok do
      if Process.get(:pointer_renamed, false) and Path.basename(path) != "journal" do
        Process.delete(:pointer_renamed)
        barrier("pointer_sync")
      end

      if Path.basename(path) == "journal" do
        record = Process.get(:journal_record)

        case {record["phase"], record["actions"]} do
          {"applying", []} -> barrier("before_dispatch")
          {"committing", _} -> barrier("commit_intent")
          {"pointer_committed", _} -> barrier("pointer_committed")
          {"complete", _} -> barrier("after_finalization")
          _ -> :ok
        end
      end
    end

    result
  end

  defp trace_action(runtime) do
    receive do
      {:trace, _controller, :call, {GenServer, :call, [^runtime, {:update, _, _}, _]}} ->
        await_update(runtime)
        barrier("during_action")

      _ ->
        trace_action(runtime)
    after
      15_000 -> exit(:action_trace_timeout)
    end
  end

  defp await_update(runtime) do
    {:messages, messages} = Process.info(runtime, :messages)

    if Enum.any?(messages, &match?({:"$gen_call", _, {:update, _, _}}, &1)) do
      :ok
    else
      :erlang.yield()
      await_update(runtime)
    end
  end

  defp barrier(boundary) do
    case :persistent_term.get(__MODULE__) do
      {^boundary, fifo} ->
        {:ok, file} = :file.open(fifo, [:write, :binary])
        :ok = :file.write(file, boundary <> "\n")
        :ok = :file.close(file)

        receive do
          :continue -> :ok
        end

      _ ->
        :ok
    end
  end
end
