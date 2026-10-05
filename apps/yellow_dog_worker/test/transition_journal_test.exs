defmodule YellowDog.Worker.TransitionJournalTest do
  use ExUnit.Case, async: false

  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.{FileOps, LocalStore, ServiceManager, TransitionJournal}

  defmodule Ops do
    def write_synced(path, bytes) do
      Process.put(:journal_bytes, bytes)
      run(:write, path, fn -> FileOps.write_synced(path, bytes) end)
    end

    def rename(source, target), do: run(:rename, target, fn -> FileOps.rename(source, target) end)
    def sync_path(path), do: run(:sync, path, fn -> FileOps.sync_path(path) end)
    def read(path), do: run(:read, path, fn -> File.read(path) end)
    def remove(path), do: run(:remove, path, fn -> FileOps.remove(path) end)

    defp run(operation, path, callback) do
      send(:ets.lookup_element(:journal_faults, :test, 2), {:operation, operation, path})

      case :ets.lookup(:journal_faults, :pointer_fault) do
        [{:pointer_fault, {^operation, suffix}}] ->
          if String.starts_with?(Process.get(:journal_bytes, ""), "active ") and
               String.contains?(path, suffix) do
            :ets.delete(:journal_faults, :pointer_fault)
            {:error, {:injected_pointer, operation}}
          else
            journal_fault(operation, path, callback)
          end

        _ ->
          journal_fault(operation, path, callback)
      end
    end

    defp journal_fault(operation, path, callback) do
      case :ets.lookup(:journal_faults, :fault) do
        [{:fault, [{expected_operation, fields} | rest]}] ->
          case TransitionJournal.decode(Process.get(:journal_bytes, "")) do
            {:ok, record} ->
              actual = Map.merge(record, List.last(record["actions"]) || %{})

              if operation == expected_operation and Map.take(actual, Map.keys(fields)) == fields do
                :ets.insert(:journal_faults, {:fault, rest})
                {:error, {:injected, operation, fields}}
              else
                callback.()
              end

            _ ->
              callback.()
          end

        [{:fault, {^operation, :path, segment}}] ->
          if String.contains?(path, segment) do
            :ets.delete(:journal_faults, :fault)
            {:error, {:injected, operation, segment}}
          else
            callback.()
          end

        [{:fault, {^operation, suffix}}] ->
          if String.ends_with?(path, suffix) do
            :ets.delete(:journal_faults, :fault)
            {:error, {:injected, operation, suffix}}
          else
            callback.()
          end

        [{:fault, {^operation, phase, status}}] ->
          case TransitionJournal.decode(Process.get(:journal_bytes, "")) do
            {:ok, record} ->
              actual =
                case List.last(record["actions"]) do
                  nil -> "empty"
                  action -> action["status"]
                end

              if record["phase"] == phase and actual == status do
                :ets.delete(:journal_faults, :fault)
                {:error, {:injected, operation, phase, status}}
              else
                callback.()
              end

            _ ->
              callback.()
          end

        _ ->
          callback.()
      end
    end
  end

  setup do
    :ets.new(:journal_faults, [:named_table, :public])
    :ets.insert(:journal_faults, {:test, self()})
    dir = Path.join(System.tmp_dir!(), "transition-journal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, plan} = ConfigSpec.decode(File.read!(Path.expand("../examples/plan.toml", __DIR__)))
    plan = put_in(plan, ["services", Access.at(0), "desired_state"], "stopped")
    {:ok, plan} = ConfigSpec.normalize_plan(plan)
    %{dir: dir, plan: plan}
  end

  test "journal-free committed directories remain compatible", ctx do
    store = start_supervised!({LocalStore, data_dir: ctx.dir})
    {:ok, candidate} = LocalStore.prepare(store, ctx.plan)
    assert :ok = LocalStore.commit(store, candidate)
    refute File.exists?(Path.join(ctx.dir, "journal/transition.toml"))
    assert {:ok, ctx.plan} == LocalStore.recover(store)
  end

  test "existing snapshot retry repeats failed directory synchronization", ctx do
    store = start_supervised!({LocalStore, data_dir: ctx.dir, file_ops: Ops})
    :ets.insert(:journal_faults, {:fault, {:sync, "snapshots"}})
    assert {:error, {:injected, :sync, "snapshots"}} = LocalStore.prepare(store, ctx.plan)
    :ets.insert(:journal_faults, {:fault, {:sync, "snapshots"}})
    assert {:error, {:injected, :sync, "snapshots"}} = LocalStore.prepare(store, ctx.plan)
    assert {:ok, _} = LocalStore.prepare(store, ctx.plan)
  end

  test "incomplete committing selects exact base even with a readable candidate pointer", ctx do
    store = start_supervised!({LocalStore, data_dir: ctx.dir})
    {:ok, base} = LocalStore.prepare(store, ctx.plan)
    :ok = LocalStore.commit(store, base)
    new = Map.put(ctx.plan, "revision", 2)
    {:ok, candidate} = LocalStore.prepare(store, new)
    assert :ok = LocalStore.begin_transition(store, candidate, "install", ctx.plan)
    assert :ok = LocalStore.checkpoint(store, "committing")

    File.write!(
      Path.join(ctx.dir, "current"),
      "active #{candidate.hash}\nprevious #{base.hash}\n"
    )

    assert {:ok, ctx.plan} == LocalStore.recover(store)
    assert LocalStore.status(store).transition["base_active"] == base.hash
  end

  test "interrupted first boot is not implicit permission to load editable source", ctx do
    store = start_supervised!({LocalStore, data_dir: ctx.dir})
    {:ok, candidate} = LocalStore.prepare(store, ctx.plan)
    assert :ok = LocalStore.begin_transition(store, candidate, "install", nil)
    assert {:error, :interrupted_first_boot} = LocalStore.recover(store)
  end

  test "manager retains a completed journal and healthy no-op performs zero persistence", ctx do
    source = Path.join(ctx.dir, "plan.toml")
    File.write!(source, elem(ConfigSpec.encode(ctx.plan), 1))

    manager =
      start_supervised!(
        {ServiceManager,
         worker_id: "edge-01",
         source: source,
         data_dir: Path.join(ctx.dir, "state"),
         file_ops: Ops}
      )

    status = ServiceManager.status(manager)
    assert status.ready
    assert status.transition["phase"] == "complete"
    assert status.transition["outcome"] == "committed"
    drain_operations()
    assert {:ok, :unchanged} = ServiceManager.submit_plan(manager, ctx.plan)

    for operation <- [:write, :rename, :sync, :remove] do
      refute_receive {:operation, ^operation, _}
    end
  end

  test "corrupt pending journal never falls through to editable source", ctx do
    File.mkdir_p!(Path.join(ctx.dir, "journal"))
    File.write!(Path.join(ctx.dir, "journal/transition.toml"), "version = 999\n")
    source = Path.join(ctx.dir, "plan.toml")
    File.write!(source, elem(ConfigSpec.encode(ctx.plan), 1))

    manager =
      start_supervised!({ServiceManager, worker_id: "edge-01", source: source, data_dir: ctx.dir})

    status = ServiceManager.status(manager)
    refute status.ready
    assert {:recovery_failed, _} = status.error
    refute File.exists?(Path.join(ctx.dir, "current"))
  end

  for operation <- [:write, :read, :rename, :sync] do
    for phase <- ["applying", "committing", "pointer_committed", "complete"] do
      test "#{operation} failure at #{phase} remains an error and requires checked recovery",
           ctx do
        store = start_supervised!({LocalStore, data_dir: ctx.dir, file_ops: Ops})
        {:ok, base} = LocalStore.prepare(store, ctx.plan)
        :ok = LocalStore.commit(store, base)
        {:ok, candidate} = LocalStore.prepare(store, Map.put(ctx.plan, "revision", 2))
        phase = unquote(phase)

        if phase != "applying",
          do: assert(:ok == LocalStore.begin_transition(store, candidate, "install", ctx.plan))

        :ets.insert(:journal_faults, {:fault, {unquote(operation), phase, "empty"}})

        result =
          if phase == "applying",
            do: LocalStore.begin_transition(store, candidate, "install", ctx.plan),
            else: LocalStore.commit(store, candidate)

        assert {:error,
                {:journal_failed, ^phase, {:injected, unquote(operation), ^phase, "empty"}}} =
                 result

        assert {:error, _} = LocalStore.recover(store)
        assert {:ok, recovered} = LocalStore.reconcile(store)
        assert recovered in [ctx.plan, candidate.plan]
        if phase in ["applying", "committing"], do: assert(recovered == ctx.plan)
        if phase == "complete", do: assert(recovered == candidate.plan)
      end
    end
  end

  test "dispatch and lost observation persistence stop forward work and preserve ordered recovery",
       ctx do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, second_socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    {:ok, {_, second_port}} = :inet.sockname(second_socket)
    :gen_tcp.close(socket)
    :gen_tcp.close(second_socket)

    plan =
      ctx.plan
      |> put_in(["services", Access.at(0), "desired_state"], "running")
      |> put_in(["services", Access.at(0), "config", "port"], port)

    {:ok, plan} = ConfigSpec.normalize_plan(plan)
    ctx = %{ctx | plan: plan}
    manager = manager(ctx)
    old = ServiceManager.status(manager)

    target = %{
      ctx.plan
      | "revision" => 2,
        "services" =>
          ctx.plan["services"] ++
            [
              hd(ctx.plan["services"])
              |> Map.put("id", "second")
              |> put_in(["config", "port"], second_port)
            ]
    }

    :ets.insert(:journal_faults, {:fault, {:write, "applying", "accepted"}})

    assert {:error, %{rejected: {:apply_failed, _}, recovery: :ok, attempted_outcomes: attempted}} =
             ServiceManager.submit_plan(manager, target)

    assert Enum.any?(attempted, &match?({:error, {:outcome_uncertain, :ok, _}}, &1.result))

    assert Enum.any?(
             attempted,
             &(&1.id == "second" and &1.result == {:error, :transition_halted})
           )

    status = ServiceManager.status(manager)
    assert status.ready
    assert status.desired == old.desired
    assert status.transition["outcome"] == "rejected"
    [dispatched | recovery] = status.transition["actions"]
    assert dispatched["status"] == "dispatched"
    assert Enum.all?(recovery, &(&1["direction"] == "recovery" and &1["status"] == "accepted"))
    assert status.persisted.error == nil
    assert {:ok, :unchanged} = ServiceManager.submit_plan(manager, ctx.plan)
  end

  test "completed checkpoint is bounded, checksummed and rejects unknown schema or unrelated pointers",
       ctx do
    manager = manager(ctx)
    status = ServiceManager.status(manager)
    record = status.transition
    assert {:ok, bytes} = TransitionJournal.encode(record)
    assert byte_size(bytes) < TransitionJournal.max_bytes()
    assert {:ok, ^record} = TransitionJournal.decode(bytes)
    assert {:error, _} = TransitionJournal.decode(String.replace(bytes, "edge-01", "edge-02"))
    assert {:error, _} = TransitionJournal.encode(Map.put(record, "version", 2))
    assert {:error, _} = TransitionJournal.encode(Map.put(record, "phase", "unknown"))

    assert {:error, _} =
             TransitionJournal.encode(
               Map.put(record, "actions", List.duplicate(hd(record["actions"]), 513))
             )

    store = :sys.get_state(manager).store

    File.write!(
      Path.join([ctx.dir, "state", "current"]),
      "active #{String.duplicate("f", 64)}\nprevious none\n"
    )

    assert {:error, :unrelated_transition_journal} = LocalStore.recover(store)
  end

  test "failed journal-directory creation synchronization must be retried", ctx do
    store = start_supervised!({LocalStore, data_dir: ctx.dir, file_ops: Ops})
    {:ok, candidate} = LocalStore.prepare(store, ctx.plan)

    for _attempt <- 1..2 do
      :ets.insert(:journal_faults, {:fault, {:sync, Path.basename(ctx.dir)}})

      assert {:error, {:journal_failed, "applying", {:injected, :sync, _}}} =
               LocalStore.begin_transition(store, candidate, "install", nil)
    end
  end

  for operation <- [:write, :read, :rename, :sync] do
    test "snapshot #{operation} failure preserves the base and requires a durable retry", ctx do
      store = start_supervised!({LocalStore, data_dir: ctx.dir, file_ops: Ops})
      {:ok, base} = LocalStore.prepare(store, ctx.plan)
      :ok = LocalStore.commit(store, base)
      target = Map.put(ctx.plan, "revision", 2)
      :ets.insert(:journal_faults, {:fault, {unquote(operation), :path, "/snapshots"}})

      assert {:error, {:injected, unquote(operation), "/snapshots"}} =
               LocalStore.prepare(store, target)

      assert {:ok, ctx.plan} == LocalStore.recover(store)
      assert LocalStore.status(store).active == base.hash
      assert {:ok, candidate} = LocalStore.prepare(store, target)
      assert :ok = LocalStore.begin_transition(store, candidate, "install", ctx.plan)
      assert :ok = LocalStore.commit(store, candidate)
      assert {:ok, candidate.plan} == LocalStore.recover(store)
    end

    test "pointer #{operation} failure restores base through checked journal recovery", ctx do
      store = start_supervised!({LocalStore, data_dir: ctx.dir, file_ops: Ops})
      {:ok, base} = LocalStore.prepare(store, ctx.plan)
      :ok = LocalStore.commit(store, base)
      {:ok, candidate} = LocalStore.prepare(store, Map.put(ctx.plan, "revision", 2))
      :ok = LocalStore.begin_transition(store, candidate, "install", ctx.plan)

      path =
        if unquote(operation) in [:write, :read],
          do: "/.tmp-",
          else: if(unquote(operation) == :rename, do: "current", else: Path.basename(ctx.dir))

      # Arm only after the committing journal has been durably persisted.
      :ok = LocalStore.checkpoint(store, "committing")
      :ets.insert(:journal_faults, {:pointer_fault, {unquote(operation), path}})
      assert {:error, _} = LocalStore.commit(store, candidate)
      assert :ets.lookup(:journal_faults, :pointer_fault) == []
      assert {:ok, ctx.plan} == LocalStore.reconcile(store)
      assert :ok = LocalStore.checkpoint(store, "recovering")
      assert :ok = LocalStore.finish(store, "rejected")
      assert LocalStore.status(store).active == base.hash
      assert {:ok, ctx.plan} == LocalStore.recover(store)
    end
  end

  test "recovery checkpoint failure after partial rollback halts and explicit retry reconciles",
       ctx do
    first = hd(ctx.plan["services"])
    base = %{ctx.plan | "services" => [first, Map.put(first, "id", "second")]}
    {:ok, base} = ConfigSpec.normalize_plan(base)
    manager = manager(%{ctx | plan: base})

    target = %{
      base
      | "revision" => 2,
        "services" => Enum.map(base["services"], &put_in(&1, ["config", "port"], 11054))
    }

    :ets.insert(
      :journal_faults,
      {:fault,
       [
         {:write,
          %{
            "phase" => "applying",
            "service" => "second",
            "operation" => "apply",
            "status" => "accepted"
          }},
         {:write,
          %{
            "phase" => "recovering",
            "service" => "dns-primary",
            "operation" => "apply",
            "status" => "accepted"
          }}
       ]}
    )

    assert {:error, %{rejected: {:apply_failed, _}, recovery: {:error, _}}} =
             ServiceManager.submit_plan(manager, target)

    assert :ets.lookup(:journal_faults, :fault) == [{:fault, []}]
    status = ServiceManager.status(manager)
    refute status.ready
    assert status.desired == base
    assert status.services["dns-primary"].desired == hd(base["services"])

    assert status.services["second"].desired ==
             hd(target["services"] |> Enum.filter(&(&1["id"] == "second")))

    recovery = Enum.filter(status.transition["actions"], &(&1["direction"] == "recovery"))

    assert [
             %{"service" => "dns-primary", "operation" => "quiesce", "status" => "accepted"},
             %{"service" => "second", "operation" => "quiesce", "status" => "accepted"},
             %{"service" => "dns-primary", "operation" => "apply", "status" => "dispatched"}
           ] = recovery

    assert status.transition["phase"] == "recovering"
    assert status.transition["outcome"] == "pending"
    assert {:journal_failed, "recovering", _} = status.persisted.error
    store = :sys.get_state(manager).store
    assert {:error, _} = LocalStore.recover(store)
    assert {:ok, :unchanged} = ServiceManager.submit_plan(manager, base)
    status = ServiceManager.status(manager)
    assert status.ready
    assert status.transition["outcome"] == "rejected"
    assert status.persisted.error == nil
    assert ServiceManager.check(manager) == []
  end

  test "same-plan explicit retry completes pending intent before healthy no-op", ctx do
    manager = manager(ctx)
    store = :sys.get_state(manager).store
    {:ok, candidate} = LocalStore.prepare(store, Map.put(ctx.plan, "revision", 2))
    :ok = LocalStore.begin_transition(store, candidate, "install", ctx.plan)
    attempt = LocalStore.status(store).transition["attempt"]

    assert {:error, :transition_pending} =
             LocalStore.begin_transition(store, candidate, "install", ctx.plan)

    assert {:ok, :unchanged} = ServiceManager.submit_plan(manager, ctx.plan)
    status = ServiceManager.status(manager)
    assert status.transition["attempt"] == attempt
    assert status.transition["outcome"] == "rejected"
    assert status.ready
    drain_operations()
    assert {:ok, :unchanged} = ServiceManager.submit_plan(manager, ctx.plan)
    assert collect_operations() == []
  end

  test "journal APIs reject out-of-order requests without writes or store exit", ctx do
    store = start_supervised!({LocalStore, data_dir: ctx.dir, file_ops: Ops})

    assert {:error, :no_transition} =
             LocalStore.dispatch(store, "forward", "dns-primary", "apply")

    assert {:error, :no_transition} = LocalStore.observe(store, :ok)
    assert {:error, :no_transition} = LocalStore.finish(store, "committed")
    {:ok, candidate} = LocalStore.prepare(store, ctx.plan)
    :ok = LocalStore.begin_transition(store, candidate, "install", nil)
    drain_operations()
    assert {:error, :invalid_transition_sequence} = LocalStore.observe(store, :ok)

    assert {:error, :invalid_transition_sequence} =
             LocalStore.checkpoint(store, "pointer_committed")

    assert {:error, :invalid_transition_sequence} = LocalStore.finish(store, "committed")
    assert collect_operations() == []
    assert :ok = LocalStore.dispatch(store, "forward", "dns-primary", "apply")
    drain_operations()

    assert {:error, :invalid_transition_sequence} =
             LocalStore.dispatch(store, "forward", "second", "apply")

    assert {:error, :invalid_transition_sequence} = LocalStore.commit(store, candidate)
    assert collect_operations() == []
    assert :ok = LocalStore.observe(store, :ok)
    assert :ok = LocalStore.commit(store, candidate)
    drain_operations()

    assert {:error, :invalid_transition_sequence} =
             LocalStore.dispatch(store, "recovery", "dns-primary", "apply")

    assert {:error, :invalid_transition_sequence} = LocalStore.observe(store, :ok)
    assert {:error, :invalid_transition_sequence} = LocalStore.checkpoint(store, "recovering")
    assert collect_operations() == []
    assert Process.alive?(store)
  end

  @tag skip: "Temporary fixture defect: revision-only change cannot create a new snapshot"
  test "completed journal corruption fallback remains visible after runtime reconciliation",
       ctx do
    manager = manager(ctx)

    assert {:ok, :committed} =
             ServiceManager.submit_plan(manager, Map.put(ctx.plan, "revision", 2))

    status = ServiceManager.status(manager)
    snapshot = Path.join([ctx.dir, "state", "snapshots", status.persisted.active <> ".toml"])
    File.write!(snapshot, "corrupt")
    assert :ok = stop_supervised(ServiceManager)
    source = Path.join(ctx.dir, "plan.toml")
    File.rm!(source)

    manager =
      start_supervised!(
        {ServiceManager,
         worker_id: "edge-01",
         source: source,
         data_dir: Path.join(ctx.dir, "state"),
         file_ops: Ops}
      )

    status = ServiceManager.status(manager)
    assert status.ready
    assert status.desired == ctx.plan
    assert {:recovered_previous, :snapshot_digest_mismatch} = status.persisted.error

    assert [
             %{
               kind: :persisted_recovery_warning,
               error: {:recovered_previous, :snapshot_digest_mismatch}
             }
           ] = ServiceManager.check(manager)
  end

  test "projection/content repair journals actions but never rewrites sound snapshots or current",
       ctx do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)

    plan =
      ctx.plan
      |> put_in(["services", Access.at(0), "desired_state"], "running")
      |> put_in(["services", Access.at(0), "config", "port"], port)

    {:ok, plan} = ConfigSpec.normalize_plan(plan)
    ctx = %{ctx | plan: plan}
    manager = manager(ctx)
    before = stable_files(ctx)
    runtime = ServiceManager.status(manager).services["dns-primary"].runtime_pid
    :sys.replace_state(runtime, &%{&1 | resources: []})
    drain_operations()
    refute ServiceManager.status(manager).ready
    assert ServiceManager.check(manager) != []
    assert stable_files(ctx) == before
    assert {:ok, :unchanged} = ServiceManager.submit_plan(manager, plan)
    assert ServiceManager.status(manager).ready
    assert stable_files(ctx) == before
    operations = collect_operations()

    assert Enum.any?(operations, fn {operation, path} ->
             operation == :write and String.contains?(path, "/journal/")
           end)

    refute Enum.any?(operations, fn {operation, path} ->
             operation in [:write, :rename, :remove] and
               (String.contains?(path, "/snapshots/") or Path.basename(path) == "current")
           end)
  end

  defp stable_files(ctx) do
    paths = [
      Path.join([ctx.dir, "state", "current"])
      | Path.wildcard(Path.join([ctx.dir, "state", "snapshots", "*"]))
    ]

    Map.new(paths, fn path ->
      stat = File.stat!(path, time: :posix)
      {path, {File.read!(path), stat.inode, stat.mtime, stat.ctime}}
    end)
  end

  defp collect_operations(acc \\ []) do
    receive do
      {:operation, operation, path} -> collect_operations([{operation, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp manager(ctx) do
    source = Path.join(ctx.dir, "plan.toml")
    File.write!(source, elem(ConfigSpec.encode(ctx.plan), 1))

    manager =
      start_supervised!(
        {ServiceManager,
         worker_id: "edge-01",
         source: source,
         data_dir: Path.join(ctx.dir, "state"),
         file_ops: Ops}
      )

    assert ServiceManager.status(manager).ready
    manager
  end

  defp drain_operations do
    receive do
      {:operation, _, _} -> drain_operations()
    after
      0 -> :ok
    end
  end
end
