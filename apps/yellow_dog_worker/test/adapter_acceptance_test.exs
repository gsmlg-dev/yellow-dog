defmodule YellowDog.Worker.AdapterAcceptanceTest do
  use ExUnit.Case, async: false

  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.{DnsAdapter, ServiceController, ServiceManager}

  defmodule ObservationProxy do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok, Map.new(opts) |> Map.merge(%{updated: false, fired: false, observations: 0})}
    end

    @impl true
    def handle_call({:update, service, resources}, _from, state) do
      result = DnsAdapter.update(state.runtime, service, resources)
      send(state.test, {:update_ack, self(), result})
      {:reply, result, %{state | updated: true, observations: 0}}
    end

    def handle_call(:status, _from, state) do
      current = DnsAdapter.status(state.runtime)
      observations = state.observations + 1

      if state.updated and not state.fired and observations == state.fault_on do
        faulty =
          case state.fault do
            :not_ready -> %{current | ready: false}
            :identity -> %{current | loaded_resources: []}
          end

        send(state.test, {:fault_observed, self(), faulty})
        {:reply, faulty, %{state | observations: observations, fired: true}}
      else
        {:reply, current, %{state | observations: observations}}
      end
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "worker-acceptance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, plan} = ConfigSpec.decode(File.read!(Path.expand("../examples/plan.toml", __DIR__)))
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    plan = put_in(plan, ["services", Access.at(0), "config", "port"], port)
    {:ok, plan} = ConfigSpec.normalize_plan(plan)
    source = Path.join(dir, "plan.toml")
    File.write!(source, elem(ConfigSpec.encode(plan), 1))
    %{dir: dir, plan: plan, source: source, port: port}
  end

  for desired <- ["running", "stopped"] do
    @tag :adapter_acceptance
    test "controller preflights unsupported #{desired} data without changing its live runtime",
         ctx do
      controller = start_supervised!({ServiceController, []}, restart: :temporary)
      [service] = ctx.plan["services"]
      assert :ok = ServiceController.apply(controller, service, ctx.plan["resources"])
      before = ServiceController.status(controller)
      [resource] = ctx.plan["resources"]
      records = resource["content"]["records"]

      delegation = %{
        "name" => "child.example.com.",
        "type" => "NS",
        "ttl" => 300,
        "data" => %{"host" => "ns1.example.com."}
      }

      resource = put_in(resource, ["content", "records"], records ++ [delegation])
      target = Map.put(service, "desired_state", unquote(desired))

      assert {:error, {:unsupported_delegation, "example.com."}} =
               ServiceController.apply(controller, target, [resource])

      after_ = ServiceController.status(controller)
      assert after_.desired == before.desired
      assert after_.applied == before.applied
      assert after_.prepared_resources == before.prepared_resources
      assert after_.runtime_pid == before.runtime_pid
      assert after_.owned_pids == before.owned_pids
      assert after_.starts == before.starts
      assert_dns(ctx.port, "192.0.2.53")
    end
  end

  for fault <- [:not_ready, :identity] do
    @tag :adapter_acceptance
    test "controller rejects update acknowledgement with #{fault} observation", ctx do
      controller = start_supervised!({ServiceController, []}, restart: :temporary)
      [service] = ctx.plan["services"]
      assert :ok = ServiceController.apply(controller, service, ctx.plan["resources"])
      before = ServiceController.status(controller)
      changed = changed_plan(ctx.plan)
      target = Map.put(hd(changed["services"]), "id", "dns-updated")

      with_proxy(controller, unquote(fault), 1, fn proxy ->
        reply = ServiceController.apply(controller, target, changed["resources"])
        assert_receive {:update_ack, ^proxy, :ok}
        assert {:error, _} = reply
        assert_receive {:fault_observed, ^proxy, _}
        rejected = ServiceController.status(controller)
        refute rejected.ready
        assert rejected.desired == target
        assert rejected.applied == before.applied
        assert rejected.applied_resources == identities(ctx.plan["resources"])
        assert rejected.prepared_resources == identities(changed["resources"])
        assert rejected.error != nil
        assert :ok = ServiceController.apply(controller, service, ctx.plan["resources"])
        assert ServiceController.status(controller).ready
        assert_dns(ctx.port, "192.0.2.53")
      end)
    end

    for fault_on <- [1, 2] do
      @tag :adapter_acceptance
      test "manager cannot commit #{fault} observation at acceptance read #{fault_on}", ctx do
        manager =
          start_supervised!(
            {ServiceManager,
             worker_id: "edge-01", source: ctx.source, data_dir: Path.join(ctx.dir, "state")},
            restart: :temporary
          )

        before = ServiceManager.status(manager)
        controller = :sys.get_state(manager).controllers["dns-primary"]
        pointer_path = Path.join([ctx.dir, "state", "current"])
        pointer = File.read!(pointer_path)
        changed = changed_plan(ctx.plan)

        with_proxy(controller, unquote(fault), unquote(fault_on), fn proxy ->
          reply = ServiceManager.submit_plan(manager, changed)
          assert_receive {:update_ack, ^proxy, :ok}
          assert {:error, %{rejected: {:apply_failed, _}, recovery: :ok}} = reply
          assert_receive {:fault_observed, ^proxy, _}
          after_ = ServiceManager.status(manager)
          assert after_.ready
          assert after_.desired == before.desired
          assert after_.persisted.active == before.persisted.active
          assert after_.persisted.previous == before.persisted.previous
          assert File.read!(pointer_path) == pointer
          assert after_.candidate.result == reply
          assert {:ok, after_.candidate.differences} == ConfigSpec.diff(before.desired, changed)

          assert after_.services["dns-primary"].applied_resources ==
                   identities(ctx.plan["resources"])

          assert_dns(ctx.port, "192.0.2.53")
        end)

        restored = ServiceManager.status(manager).services["dns-primary"]
        assert restored.runtime_pid == before.services["dns-primary"].runtime_pid
        assert restored.owned_pids == before.services["dns-primary"].owned_pids
        assert restored.starts == before.services["dns-primary"].starts
        GenServer.stop(manager)

        recovered =
          start_supervised!(
            {ServiceManager,
             worker_id: "edge-01", source: ctx.source, data_dir: Path.join(ctx.dir, "state")},
            id: make_ref(),
            restart: :temporary
          )

        status = ServiceManager.status(recovered)
        assert status.ready
        assert status.origin == :snapshot
        assert status.desired == before.desired
        assert_dns(ctx.port, "192.0.2.53")
      end
    end
  end

  @tag :adapter_acceptance
  test "controller readiness includes observed loaded identity even without an apply", ctx do
    controller = start_supervised!({ServiceController, []}, restart: :temporary)
    [service] = ctx.plan["services"]
    assert :ok = ServiceController.apply(controller, service, ctx.plan["resources"])
    runtime = ServiceController.status(controller).runtime_pid
    original = :sys.get_state(runtime).resources

    try do
      :sys.replace_state(runtime, &%{&1 | resources: []})
      status = ServiceController.status(controller)
      refute status.ready
      assert status.applied_resources == identities(original)
      assert status.active.loaded_resources == []
    after
      :sys.replace_state(runtime, &%{&1 | resources: original})
    end
  end

  defp with_proxy(controller, fault, fault_on, callback) do
    runtime = ServiceController.status(controller).runtime_pid
    proxy_id = make_ref()

    proxy =
      start_supervised!(
        {ObservationProxy, runtime: runtime, test: self(), fault: fault, fault_on: fault_on},
        id: proxy_id
      )

    :sys.replace_state(controller, &%{&1 | runtime: proxy})

    try do
      callback.(proxy)
    after
      :sys.replace_state(controller, &%{&1 | runtime: runtime})
      stop_supervised(proxy_id)
    end
  end

  defp changed_plan(plan) do
    changed =
      update_in(plan, ["resources", Access.at(0)], fn resource ->
        resource
        |> Map.delete("digest")
        |> Map.update!("version", &(&1 + 1))
        |> update_in(["content", "records"], fn records ->
          Enum.map(records, fn record ->
            if record["type"] == "A",
              do: put_in(record, ["data", "address"], "192.0.2.99"),
              else: record
          end)
        end)
      end)

    elem(ConfigSpec.normalize_plan(changed), 1)
  end

  defp identities(resources), do: Enum.map(resources, &Map.take(&1, ~w(id version digest)))

  defp assert_dns(port, address) do
    packet =
      DNS.Message.new()
      |> DNS.Message.add_question(DNS.Message.Question.new("ns1.example.com.", 1, 1))
      |> DNS.to_iodata()

    assert {:ok, udp} = Abyss.Client.send_recv({127, 0, 0, 1}, port, packet, 1000)
    assert [record] = DNS.Message.from_iodata(udp).anlist
    assert to_string(record.data) == address
    assert {:ok, tcp} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)

    try do
      :ok = :gen_tcp.send(tcp, <<byte_size(packet)::16, packet::binary>>)
      assert {:ok, <<size::16>>} = :gen_tcp.recv(tcp, 2, 1000)
      assert {:ok, bytes} = :gen_tcp.recv(tcp, size, 1000)
      assert [record] = DNS.Message.from_iodata(bytes).anlist
      assert to_string(record.data) == address
    after
      :gen_tcp.close(tcp)
    end
  end
end
