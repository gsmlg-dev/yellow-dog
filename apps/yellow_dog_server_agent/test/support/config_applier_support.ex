defmodule YellowDog.ServerAgent.ConfigApplierTestAdapter do
  @behaviour YellowDog.ServerAgent.RuntimeAdapter

  @state_key {__MODULE__, :state}

  def configure(owner, responses \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> responses end)
    :persistent_term.put(@state_key, {owner, agent})
    agent
  end

  def clear do
    case :persistent_term.get(@state_key, nil) do
      {_owner, agent} when is_pid(agent) ->
        if Process.alive?(agent), do: Agent.stop(agent)

      _other ->
        :ok
    end

    :persistent_term.erase(@state_key)
  end

  @impl true
  def validate_config(payload), do: invoke(:validate_config, [payload], :ok)

  @impl true
  def install_config(payload, opts),
    do: invoke(:install_config, [payload, opts], {:ok, String.duplicate("a", 64)})

  @impl true
  def activate_config(revision), do: invoke(:activate_config, [revision], :ok)

  @impl true
  def restore_config(revision), do: invoke(:restore_config, [revision], :ok)

  defp invoke(callback, args, default) do
    {owner, agent} = :persistent_term.get(@state_key)
    send(owner, {:adapter_call, callback, args})

    response =
      Agent.get_and_update(agent, fn responses ->
        case Map.get(responses, callback, []) do
          [next | rest] -> {next, Map.put(responses, callback, rest)}
          [] -> {default, responses}
        end
      end)

    realize(response)
  end

  defp realize({:raise, reason}), do: raise(reason)
  defp realize({:throw, reason}), do: throw(reason)
  defp realize({:exit, reason}), do: exit(reason)

  defp realize({:run, callback}) when is_function(callback, 0),
    do: callback.()

  defp realize({:block, owner, ref, response}) do
    send(owner, {:adapter_blocked, ref})

    receive do
      {:release_adapter, ^ref} -> realize(response)
    end
  end

  defp realize(response), do: response
end

defmodule YellowDog.ServerAgent.ConfigApplierMissingRestoreAdapter do
  def validate_config(_payload), do: :ok
  def install_config(_payload, _opts), do: {:ok, String.duplicate("a", 64)}
  def activate_config(_revision), do: :ok
end

defmodule YellowDog.ServerAgent.ConfigApplierTestFileOps do
  alias YellowDog.ServerAgent.Storage.FileOps

  @actions_key {__MODULE__, :actions}

  def fail_next(phase, reason \\ :eio),
    do: :persistent_term.put(@actions_key, [{phase, reason}])

  def fail_next_two(phase, reason \\ :eio),
    do: :persistent_term.put(@actions_key, [{phase, reason}, {phase, reason}])

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
    case :persistent_term.get(@actions_key, []) do
      [{^phase, reason} | rest] ->
        if rest == [], do: clear(), else: :persistent_term.put(@actions_key, rest)
        {:error, reason}

      _other ->
        operation.()
    end
  end
end

defmodule YellowDog.ServerAgent.ConfigApplierTestApplyStore do
  use GenServer

  alias YellowDog.Sync.Error

  def start_link(snapshot, transition_result \\ :ok),
    do: GenServer.start_link(__MODULE__, {snapshot, transition_result})

  @impl true
  def init({snapshot, transition_result}),
    do: {:ok, %{snapshot: snapshot, transition_result: transition_result}}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state.snapshot}, state}

  def handle_call({:preflight, _envelope}, _from, %{snapshot: %{attempt: nil}} = state),
    do: {:reply, {:admit, :new}, state}

  def handle_call(
        {:preflight, _envelope},
        _from,
        %{snapshot: %{attempt: %{checkpoint: :unknown}}} = state
      ),
      do: {:reply, {:replay, state.snapshot}, state}

  def handle_call({:transition, :uncertain_after_side_effect, %{version: _version}}, _from, state) do
    case state.transition_result do
      :ok ->
        snapshot =
          state.snapshot
          |> put_in([:attempt, :checkpoint], :unknown)
          |> Map.put(:runtime_status, :unknown)

        {:reply, {:ok, snapshot}, %{state | snapshot: snapshot}}

      :error ->
        error = Error.new(:internal, "internal error", %{})
        {:reply, {:error, error}, state}
    end
  end

  def handle_call(:pending_publications, _from, state),
    do: {:reply, {:ok, state.snapshot.outbox}, state}
end

defmodule YellowDog.ServerAgent.ConfigApplierTestConfigStore do
  use GenServer

  def start_link(stage_result, current_result),
    do: GenServer.start_link(__MODULE__, {stage_result, current_result})

  @impl true
  def init({stage_result, current_result}),
    do: {:ok, %{stage_result: stage_result, current_result: current_result}}

  @impl true
  def handle_call({:stage, _envelope}, _from, state),
    do: {:reply, state.stage_result, state}

  def handle_call(:current, _from, state),
    do: {:reply, state.current_result, state}
end
