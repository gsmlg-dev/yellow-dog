defmodule YellowDog.Worker.ServiceManagerTest do
  use ExUnit.Case, async: false
  alias YellowDog.Worker.ServiceManager
  alias YellowDog.ConfigSpec

  test "a blocked quiesce returns a lifecycle error instead of discarding ownership", ctx do
    controller = start_supervised!({YellowDog.Worker.ServiceController, []}, restart: :temporary)
    [service] = ctx.plan["services"]

    assert :ok =
             YellowDog.Worker.ServiceController.apply(controller, service, ctx.plan["resources"])

    runtime = YellowDog.Worker.ServiceController.status(controller).runtime_pid

    {:ok, client} =
      :gen_tcp.connect({127, 0, 0, 1}, service["config"]["port"], [:binary, active: false], 1000)

    handler = tcp_owner(client, System.monotonic_time(:millisecond) + 1000)
    handler_monitor = Process.monitor(handler)
    assert :erlang.suspend_process(handler)
    assert :erlang.suspend_process(runtime)

    :erlang.trace_pattern({GenServer, :stop, 3}, true, [:local])
    :erlang.trace(controller, true, [:call])

    try do
      shutdown = Task.async(fn -> YellowDog.Worker.ServiceController.quiesce(controller) end)

      assert_receive {:trace, ^controller, :call,
                      {GenServer, :stop, [^runtime, :normal, _timeout]}},
                     1000

      assert Process.alive?(runtime)
      assert {:links, links} = Process.info(controller, :links)
      assert runtime in links
      assert_bound(service["config"]["port"])
      shutdown_ref = shutdown.ref
      refute_receive {^shutdown_ref, :ok}, 0
      assert {:error, _} = Task.await(shutdown, 10000)
      state = YellowDog.Worker.ServiceController.status(controller)
      refute state.ready
      assert_receive {:DOWN, ^handler_monitor, :process, ^handler, _}, 1000
      assert {:error, :closed} = :gen_tcp.recv(client, 0, 500)

      if Process.alive?(runtime) do
        assert state.runtime_pid == runtime
        assert_bound(service["config"]["port"])
      end
    after
      resume(runtime)
      resume(handler)
      :gen_tcp.close(client)
      :erlang.trace_pattern({GenServer, :stop, 3}, false, [:local])
    end

    assert :ok =
             YellowDog.Worker.ServiceController.apply(controller, service, ctx.plan["resources"])

    assert_dns(service["config"]["port"])
  end

  test "blocked runtime stop rejects stopped intent and recovers the previous live target", ctx do
    pid = manager(ctx)
    before = ServiceManager.status(pid)
    runtime = before.services["dns-primary"].runtime_pid
    monitor = Process.monitor(runtime)
    port = ctx.plan["services"] |> hd() |> get_in(["config", "port"])
    assert_bound(port)
    assert :erlang.suspend_process(runtime)

    try do
      stopped = put_in(ctx.plan, ["services", Access.at(0), "desired_state"], "stopped")
      assert {:error, %{rejected: {:apply_failed, _}}} = ServiceManager.submit_plan(pid, stopped)
      after_ = ServiceManager.status(pid)
      assert after_.desired == before.desired
      assert after_.persisted.active == before.persisted.active

      if Process.alive?(runtime) do
        assert after_.services["dns-primary"].runtime_pid == runtime
        refute after_.ready
        assert_bound(port)
      else
        assert_receive {:DOWN, ^monitor, :process, ^runtime, _}, 1000
      end
    after
      resume(runtime)
    end

    assert {:ok, :unchanged} = ServiceManager.submit_plan(pid, ctx.plan)
    assert ServiceManager.status(pid).ready
    assert_dns(port)
  end

  test "blocked controller removal cannot be committed and keeps its owned listeners recoverable",
       ctx do
    pid = manager(ctx)
    before = ServiceManager.status(pid)
    controller = :sys.get_state(pid).controllers["dns-primary"]
    runtime = before.services["dns-primary"].runtime_pid
    port = ctx.plan["services"] |> hd() |> get_in(["config", "port"])
    assert_dns(port)
    assert :erlang.suspend_process(controller)

    try do
      empty = %{ctx.plan | "services" => [], "resources" => []}
      assert {:error, %{rejected: {:apply_failed, _}}} = ServiceManager.submit_plan(pid, empty)
      after_ = ServiceManager.status(pid)
      assert after_.desired == before.desired
      assert after_.persisted.active == before.persisted.active

      if Process.alive?(controller) do
        assert :sys.get_state(pid).controllers["dns-primary"] == controller
        assert Process.alive?(runtime)
        refute after_.ready
      end
    after
      resume(controller)
    end

    assert {:ok, :unchanged} = ServiceManager.submit_plan(pid, ctx.plan)
    assert ServiceManager.status(pid).ready
    assert_dns(port)
  end

  test "blocked removal after automatic runtime repair still owns the replacement runtime", ctx do
    pid = manager(ctx)
    before = ServiceManager.status(pid)
    controller = :sys.get_state(pid).controllers["dns-primary"]
    original = before.services["dns-primary"].runtime_pid
    original_monitor = Process.monitor(original)
    Process.exit(original, :kill)
    assert_receive {:DOWN, ^original_monitor, :process, ^original, :killed}, 1000
    send(controller, :repair)
    YellowDog.Worker.ServiceController.status(controller)
    assert ServiceManager.status(pid).ready
    repaired = YellowDog.Worker.ServiceController.status(controller)
    assert repaired.ready
    runtime = repaired.runtime_pid
    refute runtime == original
    runtime_monitor = Process.monitor(runtime)
    assert :erlang.suspend_process(runtime)
    assert :erlang.suspend_process(controller)

    try do
      empty = %{ctx.plan | "services" => [], "resources" => []}
      assert {:error, %{rejected: {:apply_failed, _}}} = ServiceManager.submit_plan(pid, empty)
      assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _}, 1000
      assert ServiceManager.status(pid).desired == before.desired
      assert ServiceManager.status(pid).persisted.active == before.persisted.active
    after
      resume(runtime)
      resume(controller)
    end

    assert {:ok, :unchanged} = ServiceManager.submit_plan(pid, ctx.plan)
    assert ServiceManager.status(pid).ready
    assert_dns(ctx.plan["services"] |> hd() |> get_in(["config", "port"]))
  end

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

  @tag :adapter_acceptance
  test "unsupported stopped first boot never prepares or commits adapter data", ctx do
    rejected = ctx.plan |> stopped_plan() |> delegation_plan()
    assert {:ok, _} = ConfigSpec.normalize_plan(rejected)
    write(ctx.source, rejected)
    pid = manager(ctx)
    status = ServiceManager.status(pid)
    refute status.ready
    assert status.desired == nil
    assert status.services == %{}

    assert status.error ==
             {:adapter_rejected, "dns-primary", {:unsupported_delegation, "example.com."}}

    assert status.persisted.active == nil
    assert snapshot_files(ctx) == []
    assert_listeners_free(hd(ctx.plan["services"])["config"]["port"])
  end

  @tag :adapter_acceptance
  test "unsupported stopped update preserves the complete stopped snapshot", ctx do
    stopped = stopped_plan(ctx.plan)
    write(ctx.source, stopped)
    pid = manager(ctx)
    before = ServiceManager.status(pid)
    disk = snapshot_files(ctx)
    pointer = File.read!(Path.join([ctx.dir, "state", "current"]))

    assert {:error, {:adapter_rejected, "dns-primary", {:unsupported_delegation, "example.com."}}} =
             ServiceManager.submit_plan(pid, delegation_plan(stopped))

    after_ = ServiceManager.status(pid)
    assert after_.desired == before.desired
    assert after_.persisted == before.persisted
    assert after_.services == before.services
    assert after_.candidate == nil
    assert snapshot_files(ctx) == disk
    assert File.read!(Path.join([ctx.dir, "state", "current"])) == pointer
    assert_listeners_free(hd(stopped["services"])["config"]["port"])
    GenServer.stop(pid)
    recovered = manager(ctx) |> ServiceManager.status()
    assert recovered.ready
    assert recovered.desired == before.desired
    assert recovered.services["dns-primary"].runtime_pid == nil
  end

  for desired_state <- ["running", "stopped"] do
    @tag :adapter_acceptance
    test "unsupported #{desired_state} candidate cannot quiesce remove or persist a live target",
         ctx do
      pid = manager(ctx)
      before = ServiceManager.status(pid)
      controllers = :sys.get_state(pid).controllers
      disk = snapshot_files(ctx)
      pointer = File.read!(Path.join([ctx.dir, "state", "current"]))
      port = hd(ctx.plan["services"])["config"]["port"]

      rejected =
        ctx.plan
        |> delegation_plan()
        |> put_in(["services", Access.at(0), "id"], "dns-replacement")
        |> put_in(["services", Access.at(0), "desired_state"], unquote(desired_state))

      assert {:error,
              {:adapter_rejected, "dns-replacement", {:unsupported_delegation, "example.com."}}} =
               ServiceManager.submit_plan(pid, rejected)

      after_ = ServiceManager.status(pid)
      assert after_.ready
      assert after_.desired == before.desired
      assert after_.persisted == before.persisted
      assert after_.services == before.services
      assert :sys.get_state(pid).controllers == controllers
      assert snapshot_files(ctx) == disk
      assert File.read!(Path.join([ctx.dir, "state", "current"])) == pointer
      assert_bound(port)
      assert_dns(port)
    end
  end

  @tag :adapter_acceptance
  test "rejected stopped data cannot quiesce the same running instance", ctx do
    pid = manager(ctx)
    before = ServiceManager.status(pid)
    disk = snapshot_files(ctx)
    pointer_path = Path.join([ctx.dir, "state", "current"])
    pointer = File.read!(pointer_path)
    rejected = ctx.plan |> stopped_plan() |> delegation_plan()

    assert {:error, {:adapter_rejected, "dns-primary", {:unsupported_delegation, "example.com."}}} =
             ServiceManager.submit_plan(pid, rejected)

    after_ = ServiceManager.status(pid)
    assert after_.desired == before.desired
    assert after_.persisted == before.persisted
    assert after_.services == before.services
    assert snapshot_files(ctx) == disk
    assert File.read!(pointer_path) == pointer
    assert_bound(hd(ctx.plan["services"])["config"]["port"])
    assert_dns(hd(ctx.plan["services"])["config"]["port"])
  end

  @tag :adapter_acceptance
  test "supported stopped preparation does not bind even occupied listener ports", ctx do
    stopped = stopped_plan(ctx.plan)
    port = hd(stopped["services"])["config"]["port"]
    {:ok, tcp} = :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}])

    {:ok, udp} =
      Abyss.Transport.UDP.Unicast.listen(port,
        ip: {127, 0, 0, 1},
        reuseaddr: false,
        reuseport: false
      )

    try do
      write(ctx.source, stopped)
      pid = manager(ctx)
      status = ServiceManager.status(pid)
      assert status.ready
      assert status.services["dns-primary"].runtime_pid == nil
      assert status.services["dns-primary"].starts == 0
      assert status.services["dns-primary"].owned_pids == []
      updated = update_address(stopped, "192.0.2.99")
      assert {:ok, :committed} = ServiceManager.submit_plan(pid, updated)
      assert ServiceManager.status(pid).services["dns-primary"].starts == 0
      :gen_tcp.close(tcp)
      :inet.close(udp)
      running = put_in(updated, ["services", Access.at(0), "desired_state"], "running")
      assert {:ok, :committed} = ServiceManager.submit_plan(pid, running)
      assert ServiceManager.status(pid).ready
      assert_dns(port)
    after
      :gen_tcp.close(tcp)
      :inet.close(udp)
    end
  end

  @tag :candidate_diff
  test "first boot exposes candidate additions without a confirmed baseline", ctx do
    pid = manager(ctx)
    status = ServiceManager.status(pid)
    assert status.ready
    assert status.candidate.base_digest == nil
    assert {:ok, status.candidate.digest} == ConfigSpec.plan_digest(ctx.plan)
    assert status.candidate.result == {:ok, :committed}

    assert status.candidate.differences == %{
             "services" => %{
               "added" => ["dns-primary"],
               "replaced" => [],
               "removed" => [],
               "lifecycle" => []
             },
             "resources" => %{
               "added" => ["zone-example"],
               "replaced" => [],
               "removed" => []
             }
           }

    assert status.desired == normalized(ctx.plan)
    GenServer.stop(pid)
    recovered = manager(ctx) |> ServiceManager.status()
    assert recovered.origin == :snapshot
    assert recovered.desired == status.desired
    assert recovered.candidate == nil
  end

  @tag :candidate_diff
  test "candidate differences describe additions replacements lifecycle and removals", ctx do
    pid = manager(ctx)
    initial = ServiceManager.status(pid)
    [service] = ctx.plan["services"]
    [resource] = ctx.plan["resources"]
    second_resource = Map.put(resource, "id", "zone-second")

    second_service =
      service
      |> Map.put("id", "dns-secondary")
      |> Map.put("desired_state", "stopped")
      |> Map.put("resources", ["zone-second"])
      |> put_in(["config", "port"], free_port())

    added = %{
      ctx.plan
      | "services" => [second_service, service],
        "resources" => [second_resource, resource]
    }

    write(ctx.source, added)
    assert {:ok, :committed} = ServiceManager.reload(pid)
    status = ServiceManager.status(pid)
    assert {:ok, status.candidate.base_digest} == ConfigSpec.plan_digest(initial.desired)
    assert {:ok, status.candidate.digest} == ConfigSpec.plan_digest(added)
    assert {:ok, status.candidate.differences} == ConfigSpec.diff(initial.desired, added)
    assert status.candidate.differences["services"]["added"] == ["dns-secondary"]
    assert status.candidate.differences["resources"]["added"] == ["zone-second"]
    assert status.candidate.result == {:ok, :committed}
    assert status.services["dns-secondary"].runtime_pid == nil

    replaced =
      added
      |> put_in(["services", Access.at(0), "config", "port"], free_port())
      |> Map.put("resources", [
        second_resource,
        hd(update_address(ctx.plan, "192.0.2.99")["resources"])
      ])

    assert {:ok, :committed} = ServiceManager.submit_plan(pid, replaced)
    status = ServiceManager.status(pid)
    assert {:ok, status.candidate.base_digest} == ConfigSpec.plan_digest(added)
    assert {:ok, status.candidate.digest} == ConfigSpec.plan_digest(replaced)
    assert {:ok, status.candidate.differences} == ConfigSpec.diff(added, replaced)
    assert status.candidate.differences["services"]["replaced"] == ["dns-secondary"]
    assert status.candidate.differences["resources"]["replaced"] == ["zone-example"]
    assert status.candidate.result == {:ok, :committed}

    assert status.services["dns-primary"].runtime_pid ==
             initial.services["dns-primary"].runtime_pid

    assert status.services["dns-secondary"].runtime_pid == nil

    stopped = put_in(replaced, ["services", Access.at(1), "desired_state"], "stopped")
    assert {:ok, :committed} = ServiceManager.submit_plan(pid, stopped)
    status = ServiceManager.status(pid)
    assert {:ok, status.candidate.differences} == ConfigSpec.diff(replaced, stopped)

    assert status.candidate.differences["services"]["lifecycle"] ==
             [%{"id" => "dns-primary", "from" => "running", "to" => "stopped"}]

    assert status.services["dns-primary"].runtime_pid == nil
    assert status.candidate.result == {:ok, :committed}

    assert {:ok, :committed} = ServiceManager.submit_plan(pid, replaced)
    status = ServiceManager.status(pid)
    assert {:ok, status.candidate.differences} == ConfigSpec.diff(stopped, replaced)

    assert status.candidate.differences["services"]["lifecycle"] ==
             [%{"id" => "dns-primary", "from" => "stopped", "to" => "running"}]

    assert status.services["dns-primary"].runtime_pid != nil
    assert status.candidate.result == {:ok, :committed}

    empty = %{replaced | "services" => [], "resources" => []}
    assert {:ok, :committed} = ServiceManager.submit_plan(pid, empty)
    status = ServiceManager.status(pid)
    assert {:ok, status.candidate.base_digest} == ConfigSpec.plan_digest(replaced)
    assert {:ok, status.candidate.digest} == ConfigSpec.plan_digest(empty)
    assert {:ok, status.candidate.differences} == ConfigSpec.diff(replaced, empty)
    assert status.candidate.differences["services"]["removed"] == ["dns-primary", "dns-secondary"]
    assert status.candidate.differences["resources"]["removed"] == ["zone-example", "zone-second"]
    assert status.candidate.result == {:ok, :committed}
    assert status.desired == normalized(empty)
    assert status.services == %{}
    assert status.ready
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

  @tag :candidate_diff
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
    assert last.candidate.base_digest == last.candidate.digest
    assert last.candidate.result == {:ok, :unchanged}
    assert {:ok, last.candidate.differences} == ConfigSpec.diff(first.desired, ctx.plan)

    assert last.candidate.differences["services"] == %{
             "added" => [],
             "replaced" => [],
             "removed" => [],
             "lifecycle" => []
           }

    assert last.candidate.differences["resources"] == %{
             "added" => [],
             "replaced" => [],
             "removed" => []
           }

    revised = Map.put(ctx.plan, "revision", ctx.plan["revision"] + 1)
    assert {:ok, :unchanged} = ServiceManager.submit_plan(pid, revised)
    revised_status = ServiceManager.status(pid)
    assert revised_status.candidate == last.candidate
    assert revised_status.desired == first.desired
    assert revised_status.persisted == first.persisted
    assert File.stat!(current, time: :posix) == first_stat

    assert revised_status.services["dns-primary"].runtime_pid ==
             first.services["dns-primary"].runtime_pid
  end

  @tag :candidate_diff
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
    assert after_.candidate == nil
    assert after_.persisted == before.persisted

    invalid = Map.delete(ctx.plan, "resources")
    assert {:error, [_ | _]} = ServiceManager.submit_plan(pid, invalid)
    assert ServiceManager.status(pid).candidate == nil
    assert ServiceManager.status(pid).desired == before.desired
    assert ServiceManager.status(pid).persisted == before.persisted

    write(ctx.source, ctx.plan)
    assert {:ok, :unchanged} = ServiceManager.reload(pid)
    assert ServiceManager.status(pid).candidate.result == {:ok, :unchanged}
  end

  @tag :candidate_diff
  test "failed listener installation rolls back every service and persists previous target",
       ctx do
    pid = manager(ctx)
    before = ServiceManager.status(pid)
    {:ok, occupied} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(occupied) end)
    {:ok, {_, port}} = :inet.sockname(occupied)
    rejected = put_in(ctx.plan, ["services", Access.at(0), "config", "port"], port)

    reply = ServiceManager.submit_plan(pid, rejected)
    assert {:error, %{rejected: {:apply_failed, _}, recovery: :ok}} = reply

    after_ = ServiceManager.status(pid)
    assert after_.ready
    assert after_.desired == before.desired
    assert after_.persisted.active == before.persisted.active
    assert {:ok, after_.candidate.base_digest} == ConfigSpec.plan_digest(before.desired)
    assert {:ok, after_.candidate.digest} == ConfigSpec.plan_digest(rejected)
    assert after_.candidate.digest != after_.candidate.base_digest
    assert {:ok, after_.candidate.differences} == ConfigSpec.diff(before.desired, rejected)
    assert after_.candidate.differences["services"]["replaced"] == ["dns-primary"]
    assert after_.candidate.result == reply

    assert {:ok, :unchanged} = ServiceManager.reload(pid)
    recovered = ServiceManager.status(pid)
    assert recovered.candidate.base_digest == after_.candidate.base_digest
    assert recovered.candidate.digest == recovered.candidate.base_digest
    assert recovered.candidate.result == {:ok, :unchanged}
    assert {:ok, recovered.candidate.differences} == ConfigSpec.diff(before.desired, ctx.plan)
  end

  @tag :candidate_diff
  test "invalid first boot remains inspectable and explicit reload can recover", ctx do
    File.write!(ctx.source, "garbage")
    pid = manager(ctx)
    refute ServiceManager.status(pid).ready
    assert ServiceManager.status(pid).desired == nil
    assert ServiceManager.status(pid).candidate == nil
    write(ctx.source, ctx.plan)
    assert {:ok, :committed} = ServiceManager.reload(pid)
    assert ServiceManager.status(pid).ready
    assert ServiceManager.status(pid).candidate.base_digest == nil
    assert ServiceManager.status(pid).candidate.result == {:ok, :committed}
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

  @tag :candidate_diff
  test "identity mismatch and explicit empty plans have distinct semantics", ctx do
    pid = manager(ctx)

    assert {:error, :worker_identity_mismatch} =
             ServiceManager.submit_plan(pid, Map.put(ctx.plan, "worker_id", "another"))

    assert ServiceManager.status(pid).candidate == nil

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

  defp stopped_plan(plan),
    do: put_in(plan, ["services", Access.at(0), "desired_state"], "stopped")

  defp delegation_plan(plan) do
    update_in(plan, ["resources", Access.at(0)], fn resource ->
      resource
      |> Map.delete("digest")
      |> Map.update!("version", &(&1 + 1))
      |> update_in(["content", "records"], fn records ->
        records ++
          [
            %{
              "name" => "child.example.com.",
              "type" => "NS",
              "ttl" => 300,
              "data" => %{"host" => "ns1.example.com."}
            }
          ]
      end)
    end)
  end

  defp snapshot_files(ctx) do
    Path.wildcard(Path.join([ctx.dir, "state", "snapshots", "*"]))
    |> Enum.map(&{&1, File.read!(&1)})
  end

  defp assert_listeners_free(port) do
    assert {:ok, tcp} = :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}])
    :gen_tcp.close(tcp)

    assert {:ok, udp} =
             Abyss.Transport.UDP.Unicast.listen(port,
               ip: {127, 0, 0, 1},
               reuseaddr: false,
               reuseport: false
             )

    :inet.close(udp)
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

  defp resume(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
  catch
    :error, :badarg -> :ok
  end

  defp tcp_owner(client, deadline) do
    {:ok, {_, client_port}} = :inet.sockname(client)

    owner =
      Enum.find_value(:erlang.ports(), fn socket ->
        with {:ok, {{127, 0, 0, 1}, ^client_port}} <- :inet.peername(socket),
             {:connected, owner} <- :erlang.port_info(socket, :connected),
             {:current_stacktrace, stack} <- Process.info(owner, :current_stacktrace),
             true <-
               Enum.any?(stack, fn {module, function, _, _} ->
                 module == :prim_inet and function in [:recv0, :recv]
               end) do
          owner
        else
          _ -> nil
        end
      end)

    cond do
      is_pid(owner) -> owner
      System.monotonic_time(:millisecond) < deadline -> tcp_owner(client, deadline)
      true -> flunk("TCP session never reached its receive")
    end
  end

  defp assert_bound(port) do
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)
    :gen_tcp.close(socket)

    assert {:error, :eaddrinuse} =
             Abyss.Transport.UDP.Unicast.listen(port,
               ip: {127, 0, 0, 1},
               reuseaddr: false,
               reuseport: false
             )
  end

  defp assert_dns(port) do
    packet =
      DNS.Message.new()
      |> DNS.Message.add_question(DNS.Message.Question.new("ns1.example.com.", 1, 1))
      |> DNS.to_iodata()

    assert {:ok, udp} = Abyss.Client.send_recv({127, 0, 0, 1}, port, packet, 1000)
    assert [%{type: %{value: <<1::16>>}}] = DNS.Message.from_iodata(udp).anlist
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
    :ok = :gen_tcp.send(socket, <<byte_size(packet)::16, packet::binary>>)
    assert {:ok, <<size::16>>} = :gen_tcp.recv(socket, 2, 1000)
    assert {:ok, tcp} = :gen_tcp.recv(socket, size, 1000)
    :gen_tcp.close(socket)
    assert [%{type: %{value: <<1::16>>}}] = DNS.Message.from_iodata(tcp).anlist
  end

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
