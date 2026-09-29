defmodule YellowDog.Worker.ServiceManager do
  @moduledoc "The single complete-plan execution and persistence entry point."
  use GenServer
  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.{ConfigLoader, LocalStore, ServiceController}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def reload(server), do: GenServer.call(server, :reload, 120_000)
  def submit_plan(server, plan), do: GenServer.call(server, {:submit, plan}, 120_000)
  def status(server), do: GenServer.call(server, :status, 30_000)
  def check(server), do: GenServer.call(server, :check, 30_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, store} <- LocalStore.start_link(data_dir: Keyword.fetch!(opts, :data_dir)) do
      state = %{
        store: store,
        worker_id: Keyword.fetch!(opts, :worker_id),
        source: Keyword.fetch!(opts, :source),
        plan: nil,
        controllers: %{},
        error: nil,
        outcomes: [],
        origin: nil
      }

      {:ok, state, {:continue, :boot}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:boot, state) do
    case LocalStore.recover(state.store) do
      {:ok, nil} ->
        {_reply, state} = load_source(state)
        {:noreply, %{state | origin: :source}}

      {:ok, plan} ->
        case validate(plan, state) do
          {:ok, plan} ->
            {result, state} = apply_services(plan, %{state | plan: plan, origin: :snapshot})
            if result != :ok, do: Process.send_after(self(), :repair, 1000)
            {:noreply, %{state | error: error(result)}}

          {:error, reason} ->
            {:noreply, %{state | error: reason}}
        end

      {:error, reason} ->
        {:noreply, %{state | error: {:recovery_failed, reason}}}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {reply, state} = load_source(state)
    {:reply, reply, state}
  end

  def handle_call({:submit, plan}, _from, state) do
    {reply, state} = submit(plan, state)
    {:reply, reply, state}
  end

  def handle_call(:status, _from, state), do: {:reply, inspect_state(state), state}
  def handle_call(:check, _from, state), do: {:reply, differences(state), state}

  @impl true
  def handle_info({:EXIT, store, reason}, %{store: store} = state),
    do: {:stop, {:store_exit, reason}, state}

  def handle_info({:EXIT, pid, reason}, state) do
    if Enum.any?(state.controllers, fn {_id, controller} -> controller == pid end) do
      Process.send_after(self(), :repair, 200)
      {:noreply, %{state | error: {:controller_exit, reason}}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:repair, %{plan: nil} = state), do: {:noreply, state}

  def handle_info(:repair, state) do
    {result, state} = apply_services(state.plan, state)
    if result != :ok, do: Process.send_after(self(), :repair, 1000)
    {:noreply, %{state | error: error(result)}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.controllers, fn {_id, pid} -> stop(pid) end)
    stop(state.store)
  end

  defp load_source(state) do
    case ConfigLoader.load(state.source, state.worker_id) do
      {:ok, plan} -> submit(plan, state)
      {:error, reason} -> {{:error, reason}, %{state | error: reason}}
    end
  end

  defp submit(candidate, state) do
    with {:ok, plan} <- validate(candidate, state),
         {:ok, digest} <- ConfigSpec.plan_digest(plan) do
      same = state.plan != nil and ConfigSpec.plan_digest(state.plan) == {:ok, digest}

      if same and LocalStore.recover(state.store) == {:ok, state.plan} and
           LocalStore.status(state.store).error == nil do
        {result, state} = apply_services(state.plan, state)
        {if(result == :ok, do: {:ok, :unchanged}, else: result), %{state | error: error(result)}}
      else
        install(plan, state)
      end
    else
      {:error, reason} -> {{:error, reason}, %{state | error: reason}}
    end
  end

  defp validate(plan, state) do
    with {:ok, normalized} <- ConfigSpec.normalize_plan(plan) do
      if normalized["worker_id"] == state.worker_id,
        do: {:ok, normalized},
        else: {:error, :worker_identity_mismatch}
    end
  end

  defp install(plan, state) do
    case LocalStore.prepare(state.store, plan) do
      {:ok, candidate} ->
        {applied, next} = apply_services(plan, state)

        case applied do
          :ok ->
            case LocalStore.commit(state.store, candidate) do
              :ok -> {{:ok, :committed}, %{next | plan: plan, error: nil}}
              {:error, reason} -> recover_failure({:commit_failed, reason}, next, state.plan)
            end

          {:error, reason} ->
            recover_failure({:apply_failed, reason}, next, state.plan)
        end

      {:error, reason} ->
        {{:error, reason}, %{state | error: {:prepare_failed, reason}}}
    end
  end

  defp recover_failure(reason, state, previous) do
    attempted_outcomes = state.outcomes

    recovered =
      case LocalStore.recover(state.store) do
        {:ok, plan} -> plan
        {:error, _} -> previous
      end

    target = recovered || empty_plan(state)
    {rollback, state} = apply_services(target, state)
    if rollback != :ok, do: Process.send_after(self(), :repair, 1000)

    failure = %{
      rejected: reason,
      recovery: rollback,
      recovered_revision: recovered && recovered["revision"],
      attempted_outcomes: attempted_outcomes
    }

    {{:error, failure}, %{state | plan: recovered, error: failure}}
  end

  defp apply_services(plan, state) do
    target_ids = MapSet.new(Enum.map(plan["services"], & &1["id"]))

    {removed, retained} =
      Enum.split_with(state.controllers, fn {id, _} -> not MapSet.member?(target_ids, id) end)

    Enum.each(removed, fn {_id, pid} -> stop(pid) end)
    state = %{state | controllers: Map.new(retained), outcomes: []}

    # Release every changing binding first, including during rollback. Otherwise
    # two valid instances exchanging ports would conflict with each other's old listeners.
    Enum.each(plan["services"], fn service ->
      case Map.get(state.controllers, service["id"]) do
        pid when is_pid(pid) ->
          current = observation(pid)

          if current[:desired] &&
               (service["desired_state"] == "stopped" or
                  current.desired["config"] != service["config"]) do
            ServiceController.quiesce(pid)
          end

        _ ->
          :ok
      end
    end)

    # Release stopped bindings before starting other instances that may reuse them.
    services = Enum.sort_by(plan["services"], &(&1["desired_state"] != "stopped"))

    state =
      Enum.reduce(services, state, fn service, acc ->
        id = service["id"]
        {pid, acc} = controller(acc, id)
        resources = Enum.filter(plan["resources"], &(&1["id"] in service["resources"]))
        result = call_controller(pid, service, resources)
        %{acc | outcomes: acc.outcomes ++ [%{id: id, result: result}]}
      end)

    failures = Enum.reject(state.outcomes, &(&1.result == :ok))
    {if(failures == [], do: :ok, else: {:error, failures}), state}
  end

  defp controller(state, id) do
    case Map.get(state.controllers, id) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {pid, state}, else: new_controller(state, id)

      _ ->
        new_controller(state, id)
    end
  end

  defp new_controller(state, id) do
    {:ok, pid} = ServiceController.start_link([])
    {pid, %{state | controllers: Map.put(state.controllers, id, pid)}}
  end

  defp call_controller(pid, service, resources) do
    ServiceController.apply(pid, service, resources)
  catch
    :exit, reason -> {:error, {:controller_unavailable, reason}}
  end

  defp inspect_state(state) do
    services = Map.new(state.controllers, fn {id, pid} -> {id, observation(pid)} end)

    %{
      live: true,
      ready: state.plan != nil and Enum.all?(services, fn {_, s} -> s[:ready] == true end),
      worker_id: state.worker_id,
      origin: state.origin,
      desired: state.plan,
      persisted: LocalStore.status(state.store),
      services: services,
      outcomes: state.outcomes,
      error: state.error,
      differences: differences(state)
    }
  end

  defp differences(state) do
    runtime =
      Enum.flat_map(state.controllers, fn {id, pid} ->
        current = observation(pid)

        cond do
          current[:ready] != true ->
            [%{service: id, kind: :runtime_not_ready}]

          (current[:desired] && current.desired["desired_state"] == "running") and
              current.active[:loaded_resources] != current.prepared_resources ->
            [
              %{
                service: id,
                kind: :loaded_resource_mismatch,
                expected: current.prepared_resources,
                actual: current.active[:loaded_resources]
              }
            ]

          true ->
            []
        end
      end)

    disk =
      case LocalStore.recover(state.store) do
        {:ok, plan} when plan == state.plan ->
          case LocalStore.status(state.store).error do
            nil -> []
            reason -> [%{kind: :persisted_recovery_warning, error: reason}]
          end

        {:ok, _} ->
          [%{kind: :persisted_plan_mismatch}]

        {:error, reason} ->
          [%{kind: :persisted_plan_unreadable, error: reason}]
      end

    runtime ++ disk
  end

  defp observation(pid) do
    ServiceController.status(pid)
  catch
    :exit, reason -> %{ready: false, error: reason}
  end

  defp empty_plan(state),
    do: %{
      "schema_version" => 1,
      "worker_id" => state.worker_id,
      "revision" => 1,
      "services" => [],
      "resources" => []
    }

  defp error(:ok), do: nil
  defp error({:error, reason}), do: reason

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)
  catch
    :exit, _ -> :ok
  end
end
