defmodule YellowDog.Worker.ServiceManagerTest do
  use ExUnit.Case, async: false
  alias YellowDog.Worker.ServiceManager
  alias YellowDog.ConfigSpec

  setup do
    dir = Path.join(System.tmp_dir!(), "worker-manager-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, bytes} = File.read(Path.expand("../examples/plan.toml", __DIR__))
    {:ok, plan} = ConfigSpec.decode(bytes)
    plan = put_in(plan, ["services", Access.at(0), "config", "port"], free_port())
    source = Path.join(dir, "plan.toml")
    write(source, plan)
    %{dir: dir, source: source, plan: plan}
  end

  test "startup uses committed snapshot and stopped updates never start DNS", ctx do
    pid = manager(ctx)
    assert ServiceManager.status(pid).ready
    initial = ServiceManager.status(pid)
    stopped = put_in(ctx.plan, ["services", Access.at(0), "desired_state"], "stopped")
    write(ctx.source, stopped)
    assert {:ok, :committed} = ServiceManager.reload(pid)
    assert ServiceManager.status(pid).services["dns-primary"].runtime_pid == nil
    updated = update_address(stopped, "192.0.2.99")
    write(ctx.source, updated)
    assert {:ok, :committed} = ServiceManager.reload(pid)
    assert ServiceManager.status(pid).services["dns-primary"].runtime_pid == nil
    GenServer.stop(pid)
    # A valid conflicting source must not override the committed stopped state at boot.
    write(ctx.source, ctx.plan)
    pid = manager(ctx)
    state = ServiceManager.status(pid)
    assert state.origin == :snapshot
    assert state.desired == normalized(updated)
    refute state.services["dns-primary"].process
    assert state.ready
    assert initial.services["dns-primary"].active.listeners == %{udp: true, tcp: true}
  end

  test "equivalent reload does not rewrite snapshot or restart healthy service", ctx do
    pid = manager(ctx)
    first = ServiceManager.status(pid)
    current = Path.join([ctx.dir, "state", "current"])
    first_stat = File.stat!(current, time: :posix)
    File.write!(ctx.source, "\n# formatting has no business meaning\n", [:append])
    assert {:ok, :unchanged} = ServiceManager.reload(pid)
    last = ServiceManager.status(pid)
    assert last.services["dns-primary"].runtime_pid == first.services["dns-primary"].runtime_pid
    assert File.stat!(current, time: :posix) == first_stat
    assert last.persisted == first.persisted
  end

  test "invalid reload preserves old snapshot and reports rejection", ctx do
    pid = manager(ctx)
    before = ServiceManager.status(pid)
    File.write!(ctx.source, "not valid = [")
    assert {:error, _} = ServiceManager.reload(pid)
    after_ = ServiceManager.status(pid)
    assert after_.desired == before.desired

    assert after_.services["dns-primary"].runtime_pid ==
             before.services["dns-primary"].runtime_pid

    assert after_.error != nil
    assert after_.ready
  end

  test "failed listener installation rolls back every service and persists previous target",
       ctx do
    pid = manager(ctx)
    before = ServiceManager.status(pid)
    {:ok, occupied} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(occupied) end)
    {:ok, {_, port}} = :inet.sockname(occupied)
    rejected = put_in(ctx.plan, ["services", Access.at(0), "config", "port"], port)

    assert {:error, %{rejected: {:apply_failed, _}, recovery: :ok}} =
             ServiceManager.submit_plan(pid, rejected)

    after_ = ServiceManager.status(pid)
    assert after_.ready
    assert after_.desired == before.desired
    assert after_.persisted.active == before.persisted.active
  end

  test "invalid first boot remains inspectable and explicit reload can recover", ctx do
    File.write!(ctx.source, "garbage")
    pid = manager(ctx)
    refute ServiceManager.status(pid).ready
    assert ServiceManager.status(pid).desired == nil
    write(ctx.source, ctx.plan)
    assert {:ok, :committed} = ServiceManager.reload(pid)
    assert ServiceManager.status(pid).ready
  end

  test "killed service recovers through its controller without a snapshot write", ctx do
    pid = manager(ctx)
    before = ServiceManager.status(pid)
    Process.exit(before.services["dns-primary"].runtime_pid, :kill)

    assert eventually(fn ->
             current = ServiceManager.status(pid)

             current.ready and
               current.services["dns-primary"].runtime_pid !=
                 before.services["dns-primary"].runtime_pid
           end)

    assert ServiceManager.status(pid).persisted == before.persisted
  end

  test "identity mismatch and explicit empty plans have distinct semantics", ctx do
    pid = manager(ctx)

    assert {:error, :worker_identity_mismatch} =
             ServiceManager.submit_plan(pid, Map.put(ctx.plan, "worker_id", "another"))

    empty = %{ctx.plan | "services" => [], "resources" => []}
    assert {:ok, :committed} = ServiceManager.submit_plan(pid, empty)
    assert ServiceManager.status(pid).ready
    assert ServiceManager.status(pid).services == %{}
  end

  test "partial multi-service apply is observed and rolled back completely", ctx do
    pid = manager(ctx)
    first = ServiceManager.status(pid)
    second_service = ctx.plan["services"] |> hd() |> Map.put("id", "dns-secondary")
    {:ok, occupied} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(occupied)
    second_service = put_in(second_service, ["config", "port"], port)
    changed = update_address(ctx.plan, "192.0.2.100")
    candidate = Map.put(changed, "services", changed["services"] ++ [second_service])

    assert {:error, %{attempted_outcomes: outcomes, recovery: :ok}} =
             ServiceManager.submit_plan(pid, candidate)

    assert Enum.any?(outcomes, &(&1.id == "dns-primary" and &1.result == :ok))
    assert Enum.any?(outcomes, &(&1.id == "dns-secondary" and match?({:error, _}, &1.result)))
    assert ServiceManager.status(pid).desired == first.desired
    assert ServiceManager.status(pid).services |> Map.keys() == ["dns-primary"]
    :gen_tcp.close(occupied)
  end

  test "missing persisted snapshot is observable and repaired without restarting healthy DNS",
       ctx do
    pid = manager(ctx)
    before = ServiceManager.status(pid)
    snapshot = Path.join([ctx.dir, "state", "snapshots", before.persisted.active <> ".toml"])
    File.rm!(snapshot)
    assert [%{kind: :persisted_plan_unreadable}] = ServiceManager.check(pid)
    assert {:ok, :committed} = ServiceManager.reload(pid)
    assert ServiceManager.check(pid) == []

    assert ServiceManager.status(pid).services["dns-primary"].runtime_pid ==
             before.services["dns-primary"].runtime_pid
  end

  test "running instances exchange bindings and failed swaps restore both listeners", ctx do
    secondary = ctx.plan["services"] |> hd() |> Map.put("id", "dns-secondary")
    secondary = put_in(secondary, ["config", "port"], free_port())
    plan = %{ctx.plan | "services" => ctx.plan["services"] ++ [secondary]}
    write(ctx.source, plan)
    pid = manager(ctx)
    [first, second] = plan["services"]

    swapped = %{
      plan
      | "services" => [
          %{first | "config" => second["config"]},
          %{second | "config" => first["config"]}
        ]
    }

    assert {:ok, :committed} = ServiceManager.submit_plan(pid, swapped)
    assert ServiceManager.status(pid).ready
    assert {:ok, :committed} = ServiceManager.submit_plan(pid, plan)
    {:ok, occupied} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(occupied)
    failing = secondary |> Map.put("id", "z-failing") |> put_in(["config", "port"], port)
    rejected = %{swapped | "services" => swapped["services"] ++ [failing]}
    assert {:error, %{recovery: :ok}} = ServiceManager.submit_plan(pid, rejected)
    assert ServiceManager.status(pid).ready
    assert ServiceManager.status(pid).desired == normalized(plan)

    for service <- plan["services"] do
      assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, service["config"]["port"], [], 1000)
      :gen_tcp.close(socket)
    end

    :gen_tcp.close(occupied)
  end

  defp manager(ctx) do
    pid =
      start_supervised!(
        {ServiceManager,
         worker_id: "edge-01", source: ctx.source, data_dir: Path.join(ctx.dir, "state")},
        id: make_ref(),
        restart: :temporary
      )

    # status serializes after boot's handle_continue.
    ServiceManager.status(pid)
    pid
  end

  defp normalized(plan), do: elem(ConfigSpec.normalize_plan(plan), 1)
  defp write(path, plan), do: File.write!(path, elem(ConfigSpec.encode(plan), 1))

  defp update_address(plan, address) do
    update_in(plan, ["resources", Access.at(0)], fn resource ->
      resource
      |> Map.delete("digest")
      |> Map.put("version", resource["version"] + 1)
      |> update_in(["content", "records"], fn records ->
        Enum.map(records, fn record ->
          if record["type"] == "A", do: put_in(record, ["data", "address"], address), else: record
        end)
      end)
    end)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp eventually(fun, left \\ 60)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, left) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(100)
          eventually(fun, left - 1)
        )
  end
end
