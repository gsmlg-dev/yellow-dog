defmodule YellowDog.Worker.ServiceManager do
  @moduledoc "The single complete-plan execution and persistence entry point."
  use GenServer
  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.{ConfigLoader, LocalStore, OwnedShutdown, ServiceController}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def reload(server), do: GenServer.call(server, :reload, 120_000)
  def submit_plan(server, plan), do: GenServer.call(server, {:submit, plan}, 120_000)
  def status(server), do: GenServer.call(server, :status, 30_000)
  def check(server), do: GenServer.call(server, :check, 30_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, store} <- LocalStore.start_link(Keyword.take(opts, [:data_dir, :file_ops])) do
      state = %{
        store: store,
        worker_id: Keyword.fetch!(opts, :worker_id),
        source: Keyword.fetch!(opts, :source),
        plan: nil,
        candidate: nil,
        controllers: %{},
        owned: %{},
        error: nil,
        outcomes: [],
        origin: nil,
        direction: nil,
        halted: false
      }

      {:ok, state, {:continue, :boot}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:boot, state) do
    case LocalStore.reconcile(state.store) do
      {:ok, nil} ->
        {_reply, state} = load_source(state)
        {:noreply, %{state | origin: :source}}

      {:ok, plan} ->
        case validate(plan, state) do
          {:ok, plan} ->
            {result, state} = restore_runtime(plan, %{state | plan: plan, origin: :snapshot})
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
  def handle_info({:runtime_ownership, pid, owned}, state) do
    case Enum.find(state.controllers, fn {_id, controller} -> controller == pid end) do
      {id, ^pid} -> {:noreply, %{state | owned: Map.put(state.owned, id, owned)}}
      nil -> {:noreply, state}
    end
  end

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

  def handle_info({:repair_service, pid}, state) do
    if pid in Map.values(state.controllers),
      do: handle_info(:repair, state),
      else: {:noreply, state}
  end

  def handle_info(:repair, %{plan: nil} = state), do: {:noreply, state}

  def handle_info(:repair, state) do
    if LocalStore.status(state.store).error == nil do
      {_reply, next} = submit(state.plan, state)
      {:noreply, next}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    results =
      Enum.map(state.controllers, fn {id, pid} ->
        OwnedShutdown.stop(pid, Map.get(state.owned, id, []), 4000)
      end)

    store_result = OwnedShutdown.stop(state.store)

    if Enum.all?([store_result | results], &(&1 == :ok)),
      do: :ok,
      else: exit({:owned_shutdown_failed, results, store_result})
  end

  defp load_source(state) do
    case ConfigLoader.load(state.source, state.worker_id) do
      {:ok, plan} -> submit(plan, state)
      {:error, reason} -> {{:error, reason}, %{state | candidate: nil, error: reason}}
    end
  end

  defp submit(candidate, state) do
    with {:ok, plan} <- validate(candidate, state),
         {:ok, digest} <- ConfigSpec.plan_digest(plan),
         {:ok, state} <- resume_pending(state),
         {:ok, diff} <- ConfigSpec.diff(state.plan || empty_plan(state), plan) do
      base_digest = state.plan && elem(ConfigSpec.plan_digest(state.plan), 1)
      same = base_digest == digest

      {reply, next} =
        if same and LocalStore.recover(state.store) == {:ok, state.plan} and
             LocalStore.status(state.store).error == nil do
          if healthy_projection?(state.plan, state) do
            {{:ok, :unchanged}, state}
          else
            repair_projection(state.plan, state)
          end
        else
          install(plan, state)
        end

      {reply,
       %{
         next
         | candidate: %{
             base_digest: base_digest,
             digest: digest,
             differences: diff,
             result: reply
           }
       }}
    else
      {:error, reason, next} -> {{:error, reason}, %{next | candidate: nil, error: reason}}
      {:error, reason} -> {{:error, reason}, %{state | candidate: nil, error: reason}}
    end
  end

  defp resume_pending(state) do
    persisted = LocalStore.status(state.store)
    record = persisted.transition

    if (is_map(record) and record["phase"] != "complete") or
         match?({:journal_failed, _, _}, persisted.error) do
      case LocalStore.reconcile(state.store) do
        {:ok, plan} -> resume_runtime(plan, state)
        {:error, :interrupted_first_boot} -> resume_runtime(nil, state)
        {:error, reason} -> {:error, {:recovery_failed, reason}, state}
      end
    else
      {:ok, state}
    end
  end

  defp resume_runtime(plan, state) do
    {result, next} = restore_runtime(plan || empty_plan(state), %{state | direction: "recovery"})

    case result do
      :ok -> {:ok, %{next | plan: plan, error: nil}}
      {:error, reason} -> {:error, {:recovery_failed, reason}, %{next | plan: plan}}
    end
  end

  defp validate(plan, state) do
    with {:ok, normalized} <- ConfigSpec.normalize_plan(plan),
         true <- normalized["worker_id"] == state.worker_id,
         :ok <- validate_services(normalized) do
      {:ok, normalized}
    else
      false -> {:error, :worker_identity_mismatch}
      error -> error
    end
  end

  defp validate_services(plan) do
    Enum.reduce_while(plan["services"], :ok, fn service, :ok ->
      resources = Enum.filter(plan["resources"], &(&1["id"] in service["resources"]))

      case ServiceController.validate(service, resources) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:adapter_rejected, service["id"], reason}}}
      end
    end)
  end

  defp install(plan, state) do
    case LocalStore.prepare(state.store, plan) do
      {:ok, candidate} ->
        case LocalStore.begin_transition(state.store, candidate, "install", state.plan) do
          :ok ->
            {applied, next} = apply_services(plan, %{state | direction: "forward"})

            case applied do
              :ok ->
                case LocalStore.commit(state.store, candidate) do
                  :ok -> {{:ok, :committed}, %{next | plan: plan, error: nil, direction: nil}}
                  {:error, reason} -> recover_failure({:commit_failed, reason}, next, state.plan)
                end

              {:error, reason} ->
                recover_failure({:apply_failed, reason}, next, state.plan)
            end

          {:error, reason} ->
            {{:error, reason}, %{state | error: reason}}
        end

      {:error, reason} ->
        {{:error, reason}, %{state | error: {:prepare_failed, reason}}}
    end
  end

  defp recover_failure(reason, state, previous) do
    attempted_outcomes = state.outcomes

    {recovered, rollback, state} =
      case LocalStore.reconcile(state.store) do
        {:ok, plan} ->
          {rollback, next} =
            restore_runtime(plan || empty_plan(state), %{state | direction: "recovery"})

          {plan, rollback, next}

        {:error, :interrupted_first_boot} ->
          {rollback, next} = restore_runtime(empty_plan(state), %{state | direction: "recovery"})
          {nil, rollback, next}

        {:error, failure} ->
          {previous, {:error, failure}, state}
      end

    failure = %{
      rejected: reason,
      recovery: rollback,
      recovered_revision: recovered && recovered["revision"],
      attempted_outcomes: attempted_outcomes
    }

    {{:error, failure}, %{state | plan: recovered, error: failure, direction: nil}}
  end

  defp healthy_projection?(plan, state) do
    MapSet.new(Map.keys(state.controllers)) == MapSet.new(Enum.map(plan["services"], & &1["id"])) and
      Enum.all?(plan["services"], fn service ->
        resources = Enum.filter(plan["resources"], &(&1["id"] in service["resources"]))

        accept_observation(:ok, service, resources, observation(state.controllers[service["id"]])) ==
          :ok
      end)
  end

  defp repair_projection(plan, state) do
    candidate = %{hash: LocalStore.status(state.store).active, plan: plan}

    case LocalStore.begin_transition(state.store, candidate, "repair", plan) do
      :ok ->
        {result, next} = apply_services(plan, %{state | direction: "forward"})

        case result do
          :ok ->
            finalized = LocalStore.finish(state.store, "repaired")

            {if(finalized == :ok, do: {:ok, :unchanged}, else: finalized),
             %{next | error: error(finalized), direction: nil}}

          {:error, reason} ->
            recover_failure({:apply_failed, reason}, next, plan)
        end

      {:error, reason} ->
        {{:error, reason}, %{state | error: reason}}
    end
  end

  defp restore_runtime(plan, state) do
    record = LocalStore.status(state.store).transition
    pending = record && record["phase"] != "complete"

    setup =
      cond do
        pending and record["phase"] in ["applying", "committing"] ->
          LocalStore.checkpoint(state.store, "recovering")

        pending ->
          :ok

        state.direction == "recovery" ->
          :ok

        true ->
          {:ok, bytes} = ConfigSpec.encode(plan)

          candidate = %{
            hash: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
            plan: plan
          }

          LocalStore.begin_transition(state.store, candidate, "repair", plan)
      end

    case setup do
      :ok ->
        {result, next} = apply_services(plan, %{state | direction: "recovery"})

        if result == :ok do
          outcome =
            cond do
              record &&
                (record["phase"] == "pointer_committed" or record["outcome"] == "committed") &&
                  pending ->
                "committed"

              pending && record["kind"] == "install" ->
                "rejected"

              true ->
                "repaired"
            end

          finalized = LocalStore.finish(state.store, outcome)
          {finalized, %{next | direction: nil}}
        else
          {result, %{next | direction: nil}}
        end

      {:error, _} = failure ->
        {failure, state}
    end
  end

  defp apply_services(plan, state) do
    target_ids = MapSet.new(Enum.map(plan["services"], & &1["id"]))

    {removed, _retained} =
      Enum.split_with(state.controllers, fn {id, _} -> not MapSet.member?(target_ids, id) end)

    state = %{state | outcomes: [], halted: false}

    state =
      Enum.reduce(removed, state, fn {id, pid}, acc ->
        {result, acc} =
          execute_action(acc, id, :remove, fn current ->
            {OwnedShutdown.stop(pid, Map.get(current.owned, id, []), 4000), current}
          end)

        next =
          if result == :ok do
            %{
              acc
              | controllers: Map.delete(acc.controllers, id),
                owned: Map.delete(acc.owned, id)
            }
          else
            case result do
              {:error, {:shutdown_failed, _result, remaining}} ->
                %{acc | owned: Map.update(acc.owned, id, remaining, &Enum.uniq(&1 ++ remaining))}

              _ ->
                acc
            end
          end

        %{next | outcomes: next.outcomes ++ [%{id: id, operation: :remove, result: result}]}
      end)

    # Release every changing binding first, including during rollback. Otherwise
    # two valid instances exchanging ports would conflict with each other's old listeners.
    state =
      Enum.reduce(plan["services"], state, fn service, acc ->
        case Map.get(state.controllers, service["id"]) do
          pid when is_pid(pid) ->
            current = observation(pid)

            if current[:desired] &&
                 (service["desired_state"] == "stopped" or
                    current.desired["config"] != service["config"]) do
              {result, acc} =
                execute_action(acc, service["id"], :quiesce, fn current ->
                  {quiesce(pid), current}
                end)

              %{
                acc
                | outcomes:
                    acc.outcomes ++ [%{id: service["id"], operation: :quiesce, result: result}]
              }
            else
              acc
            end

          _ ->
            acc
        end
      end)

    # Release stopped bindings before starting other instances that may reuse them.
    services = Enum.sort_by(plan["services"], &(&1["desired_state"] != "stopped"))

    state =
      if Enum.all?(state.outcomes, &(&1.result == :ok)) do
        Enum.reduce(services, state, fn service, acc ->
          id = service["id"]
          resources = Enum.filter(plan["resources"], &(&1["id"] in service["resources"]))

          {result, next} =
            execute_action(acc, id, :apply, fn current_state ->
              case controller(current_state, id) do
                {:ok, pid, next} ->
                  result = call_controller(pid, service, resources)
                  current = observation(pid)
                  result = accept_observation(result, service, resources, current)
                  owned = Map.get(current, :owned_pids, Map.get(next.owned, id, []))
                  {result, %{next | owned: Map.put(next.owned, id, owned)}}

                {:error, reason, next} ->
                  {{:error, reason}, next}
              end
            end)

          %{next | outcomes: next.outcomes ++ [%{id: id, result: result}]}
        end)
      else
        state
      end

    failures = Enum.reject(state.outcomes, &(&1.result == :ok))
    {if(failures == [], do: :ok, else: {:error, failures}), state}
  end

  defp execute_action(%{halted: true} = state, _id, _operation, _callback),
    do: {{:error, :transition_halted}, state}

  defp execute_action(state, id, operation, callback) do
    case LocalStore.dispatch(state.store, state.direction, id, Atom.to_string(operation)) do
      :ok ->
        {result, next} = callback.(state)

        case LocalStore.observe(state.store, result) do
          :ok ->
            {result, next}

          {:error, reason} ->
            {{:error, {:outcome_uncertain, result, reason}}, %{next | halted: true}}
        end

      {:error, reason} ->
        {{:error, {:dispatch_failed, reason}}, %{state | halted: true}}
    end
  end

  defp accept_observation(:ok, service, resources, current) do
    expected = Enum.map(resources, &Map.take(&1, ~w(id version digest)))

    if current[:ready] == true and current[:desired] == service and
         current[:applied] == service and current[:prepared_resources] == expected and
         current[:applied_resources] == expected and
         (service["desired_state"] == "stopped" or
            get_in(current, [:active, :loaded_resources]) == expected),
       do: :ok,
       else: {:error, {:service_not_applied, current}}
  end

  defp accept_observation(result, _service, _resources, _current), do: result

  defp controller(state, id) do
    case Map.get(state.controllers, id) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid, state}, else: replace_controller(state, id, pid)

      _ ->
        new_controller(state, id)
    end
  end

  defp new_controller(state, id) do
    {:ok, pid} = ServiceController.start_link(observer: self())

    {:ok, pid,
     %{
       state
       | controllers: Map.put(state.controllers, id, pid),
         owned: Map.put(state.owned, id, [])
     }}
  end

  defp replace_controller(state, id, pid) do
    case OwnedShutdown.stop(pid, Map.get(state.owned, id, [])) do
      :ok ->
        new_controller(state, id)

      {:error, {:shutdown_failed, _result, remaining} = reason} ->
        next = %{
          state
          | owned: Map.update(state.owned, id, remaining, &Enum.uniq(&1 ++ remaining))
        }

        {:error, reason, next}
    end
  end

  defp quiesce(pid) do
    ServiceController.quiesce(pid)
  catch
    :exit, reason -> {:error, {:controller_unavailable, reason}}
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
      ready: state.plan != nil and healthy_projection?(state.plan, state),
      worker_id: state.worker_id,
      origin: state.origin,
      desired: state.plan,
      candidate: state.candidate,
      persisted: Map.delete(LocalStore.status(state.store), :transition),
      transition: LocalStore.status(state.store).transition,
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
end
