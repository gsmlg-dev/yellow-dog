defmodule YellowDog.NetmanAgent.ConfigApplierTest do
  use ExUnit.Case, async: false

  Code.require_file("../../support/config_applier_support.ex", __DIR__)

  alias YellowDog.NetmanAgent.ConfigApplier
  alias YellowDog.NetmanAgent.ConfigApplierTestAdapter
  alias YellowDog.NetmanAgent.ConfigApplierTestFileOps
  alias YellowDog.NetmanAgent.ConfigApplyStore
  alias YellowDog.NetmanAgent.ConfigStore
  alias YellowDog.NetmanAgent.RuntimeAdapter
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @netman_id "netman-east-1"
  @operation "netman.profiles.replace"
  @revision String.duplicate("a", 64)
  @candidate_revision String.duplicate("b", 64)

  setup do
    previous_trap_exit = Process.flag(:trap_exit, true)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-netman-config-applier-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)
    ConfigApplierTestAdapter.configure(self())

    on_exit(fn ->
      ConfigApplierTestAdapter.clear()
      ConfigApplierTestFileOps.clear()
      File.rm_rf(data_dir)
      Process.flag(:trap_exit, previous_trap_exit)
    end)

    %{data_dir: data_dir}
  end

  test "RuntimeAdapter declares exactly the four lifecycle callbacks" do
    assert RuntimeAdapter.behaviour_info(:callbacks) |> Enum.sort() ==
             [
               activate_config: 1,
               install_config: 2,
               restore_config: 1,
               validate_config: 1
             ]
  end

  test "classifies only explicit management-connectivity fields as provisional" do
    previous = %{"profiles" => [classification_profile()]}

    connectivity_changes = [
      put_in(previous, ["profiles", Access.at(0), "interface"], "eth1"),
      put_in(previous, ["profiles", Access.at(0), "autoconnect_priority"], 10),
      put_in(previous, ["profiles", Access.at(0), "ipv4", "method"], "manual"),
      put_in(previous, ["profiles", Access.at(0), "ipv4", "address"], "192.0.2.2/24"),
      put_in(previous, ["profiles", Access.at(0), "ipv4", "gateway"], "192.0.2.1"),
      put_in(previous, ["profiles", Access.at(0), "ipv4", "dns"], ["192.0.2.53"]),
      put_in(previous, ["profiles", Access.at(0), "ipv4", "dns_search"], ["example.test"]),
      put_in(previous, ["profiles", Access.at(0), "ipv6", "method"], "manual"),
      put_in(previous, ["profiles", Access.at(0), "ipv6", "address"], "2001:db8::2/64"),
      put_in(previous, ["profiles", Access.at(0), "ipv6", "gateway"], "2001:db8::1"),
      put_in(previous, ["profiles", Access.at(0), "ipv6", "dns"], ["2001:db8::53"]),
      put_in(previous, ["profiles", Access.at(0), "ipv6", "dns_search"], ["v6.example.test"]),
      %{"profiles" => []},
      %{"profiles" => [classification_profile(), classification_profile("backup")]}
    ]

    assert Enum.all?(connectivity_changes, &ConfigApplier.connectivity_change?(&1, previous))

    non_connectivity_changes = [
      previous,
      put_in(previous, ["profiles", Access.at(0), "autoconnect"], false),
      put_in(previous, ["profiles", Access.at(0), "zone"], "trusted"),
      put_in(previous, ["profiles", Access.at(0), "ethernet", "mtu"], 1_400)
    ]

    refute Enum.any?(non_connectivity_changes, &ConfigApplier.connectivity_change?(&1, previous))
  end

  test "stages an immutable replacement before serialized side effects and publishes evidence", %{
    data_dir: data_dir
  } do
    {config_store, apply_store, applier} = start_lifecycle(data_dir)
    delivery = envelope(1)

    test_pid = self()
    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      validate_config: [
        {:run,
         fn ->
           send(test_pid, {:staged_before_validate, ConfigStore.current(config_store)})
           :ok
         end}
      ]
    })

    assert {:ok, %{status: :applied, publications: publications}} =
             ConfigApplier.apply(delivery, applier)

    assert Enum.map(publications, & &1.message.state) == [:delivered, :applying, :applied]
    assert Enum.map(publications, & &1.sequence) == [1, 2, 3]

    assert_receive {:staged_before_validate, {:ok, staged_before_validate}}
    assert staged_before_validate["payload"] == delivery.payload

    assert Enum.all?(publications, fn publication ->
             publication.message.target_type == :netman and
               publication.message.target_id == @netman_id and
               publication.message.operation == @operation
           end)

    assert_receive {:adapter_call, :validate_config, [%{"profiles" => []}]}

    digest = delivery.payload_digest

    assert_receive {:adapter_call, :install_config,
                    [
                      %{"profiles" => []},
                      [
                        version: 1,
                        digest: ^digest,
                        expected_revision: nil,
                        operation: @operation
                      ]
                    ]}

    assert_receive {:adapter_call, :activate_config, [@revision]}

    assert {:ok, staged} = ConfigStore.current(config_store)
    assert staged["payload"] == delivery.payload
    assert staged["digest"] == delivery.payload_digest

    assert {:ok, %{runtime_status: :known, known_good: known_good}} =
             ConfigApplyStore.snapshot(apply_store)

    assert known_good == %{version: 1, digest: delivery.payload_digest, revision: @revision}

    assert {:ok, %{runtime_status: :known, known_good: ^known_good}} =
             ConfigApplyStore.read_boot_state(data_dir, @netman_id)
  end

  test "boot evidence read is non-creating and rejects corrupt or wrong-target state", %{
    data_dir: data_dir
  } do
    assert {:error, :missing} = ConfigApplyStore.read_boot_state(data_dir, @netman_id)
    refute File.exists?(Path.join(data_dir, "netman"))

    {_config_store, apply_store, applier} = start_lifecycle(data_dir)
    assert {:ok, %{status: :applied}} = ConfigApplier.apply(envelope(1), applier)

    assert {:ok, %{runtime_status: :known, known_good: %{revision: @revision}}} =
             ConfigApplyStore.read_boot_state(data_dir, @netman_id)

    GenServer.stop(apply_store)
    path = Path.join([data_dir, "netman", "apply_state.json"])
    original = File.read!(path)
    File.write!(path, "{")

    assert {:error, :corrupt} = ConfigApplyStore.read_boot_state(data_dir, @netman_id)
    File.write!(path, original)
    assert {:error, :corrupt} = ConfigApplyStore.read_boot_state(data_dir, "other-netman")
    assert {:error, :invalid_options} = ConfigApplyStore.read_boot_state("relative", @netman_id)
  end

  test "validation failure publishes delivered then failed without runtime mutation", %{
    data_dir: data_dir
  } do
    ConfigApplierTestAdapter.clear()
    ConfigApplierTestAdapter.configure(self(), %{validate_config: [{:error, :invalid}]})
    {_config_store, _apply_store, applier} = start_lifecycle(data_dir)

    assert {:ok, %{status: :failed, publications: publications}} =
             ConfigApplier.apply(envelope(1), applier)

    assert Enum.map(publications, & &1.message.state) == [:delivered, :failed]
    failed = List.last(publications).message

    assert failed.failure == %{
             "phase" => "validation",
             "reason" => "runtime config validation failed"
           }

    assert failed.rollback == nil
    refute_receive {:adapter_call, :install_config, _}
    refute_receive {:adapter_call, :activate_config, _}
  end

  test "bounds a hung runtime install and leaves an unconfigured runtime replaceable", %{
    data_dir: data_dir
  } do
    ref = make_ref()

    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      install_config: [{:block, self(), ref, {:ok, @revision}}]
    })

    {_config_store, apply_store, applier} =
      start_lifecycle(data_dir, adapter_timeout: 20)

    assert {:ok, %{status: :failed, publications: publications}} =
             ConfigApplier.apply(envelope(1), applier)

    assert_receive {:adapter_blocked, ^ref}
    assert Enum.map(publications, & &1.message.state) == [:delivered, :applying, :failed]
    assert List.last(publications).message.failure["phase"] == "apply"

    assert {:ok, %{runtime_status: :unconfigured, known_good: nil}} =
             ConfigApplyStore.snapshot(apply_store)

    assert Process.alive?(applier)
  end

  test "failed replacement restores and reactivates the prior revision with rollback evidence", %{
    data_dir: data_dir
  } do
    {_config_store, apply_store, applier} = start_lifecycle(data_dir)
    first = envelope(1)

    assert {:ok, %{status: :applied}} = ConfigApplier.apply(first, applier)
    drain(apply_store)
    flush_adapter_calls()

    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      install_config: [{:error, :candidate_failed}]
    })

    second = envelope(2, expected_revision: @revision)

    assert {:ok, %{status: :failed, publications: publications}} =
             ConfigApplier.apply(second, applier)

    assert Enum.map(publications, & &1.message.state) == [:delivered, :applying, :failed]
    failed = List.last(publications).message

    assert failed.failure == %{"phase" => "apply", "reason" => "config install failed"}

    assert failed.rollback == %{
             "succeeded" => true,
             "restored_version" => 1,
             "restored_revision" => @revision,
             "reason" => nil
           }

    assert_receive {:adapter_call, :restore_config, [@revision]}
    assert_receive {:adapter_call, :activate_config, [@revision]}
  end

  test "activation failure restores the installed candidate checkpoint before reactivating a prior domain",
       %{
         data_dir: data_dir
       } do
    {_config_store, apply_store, applier} = start_lifecycle(data_dir)
    assert {:ok, %{status: :applied}} = ConfigApplier.apply(envelope(1), applier)
    drain(apply_store)
    flush_adapter_calls()

    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      install_config: [{:ok, @candidate_revision}],
      activate_config: [{:error, :candidate_failed}, :ok]
    })

    payload = %{"upstreams" => ["192.0.2.53"], "search_domains" => ["example.test"]}

    delivery =
      envelope(2,
        operation: "netman.resolved.config.update",
        payload: payload,
        expected_revision: @revision
      )

    assert {:ok, %{status: :failed}} = ConfigApplier.apply(delivery, applier)

    assert_receive {:adapter_call, :restore_config, [{:candidate, @candidate_revision}]}
    assert_receive {:adapter_call, :activate_config, [@revision]}
  end

  test "accepts Resolved update and rollback as durable config deliveries", %{
    data_dir: data_dir
  } do
    for {index, operation, payload} <- [
          {1, "netman.resolved.config.update", %{"upstreams" => [], "search_domains" => []}},
          {2, "netman.resolved.config.rollback",
           %{"target_revision" => String.duplicate("b", 64)}}
        ] do
      scoped_dir = Path.join(data_dir, Integer.to_string(index))
      File.mkdir_p!(scoped_dir)
      {config_store, apply_store, applier} = start_lifecycle(scoped_dir)
      delivery = envelope(1, operation: operation, payload: payload)

      assert {:ok, %{status: :applied}} = ConfigApplier.apply(delivery, applier)
      assert_receive {:adapter_call, :validate_config, [^payload]}
      assert_receive {:adapter_call, :install_config, [^payload, opts]}
      assert opts[:operation] == operation
      assert_receive {:adapter_call, :activate_config, [@revision]}

      stop(applier)
      stop(apply_store)
      stop(config_store)
    end
  end

  test "rejects cross-target and non-config Netman operations before staging or callbacks", %{
    data_dir: data_dir
  } do
    {config_store, _apply_store, applier} = start_lifecycle(data_dir)

    invalid_deliveries = [
      envelope(1, target_id: "netman-west-1"),
      envelope(1,
        operation: "netman.profiles.put",
        payload: classification_profile()
      )
    ]

    for delivery <- invalid_deliveries do
      assert {:error, %Error{code: :invalid}} = ConfigApplier.apply(delivery, applier)
    end

    assert {:error, %Error{code: :not_found}} = ConfigStore.current(config_store)
    refute_receive {:adapter_call, _, _}
  end

  test "terminal replay survives process restart and never repeats runtime callbacks", %{
    data_dir: data_dir
  } do
    {config_store, apply_store, applier} = start_lifecycle(data_dir)
    delivery = envelope(1)

    assert {:ok, %{status: :applied, publications: first_publications}} =
             ConfigApplier.apply(delivery, applier)

    flush_adapter_calls()
    stop(applier)
    stop(apply_store)
    stop(config_store)

    {config_store, apply_store, applier} = start_lifecycle(data_dir)

    assert {:ok, %{status: :replay, publications: replayed_publications}} =
             ConfigApplier.apply(delivery, applier)

    assert replayed_publications == first_publications
    refute_receive {:adapter_call, _, _}
    assert Process.alive?(config_store)
    assert Process.alive?(apply_store)
  end

  test "restart terminalizes an install checkpoint without a durable runtime checkpoint", %{
    data_dir: data_dir
  } do
    config_store = start_config_store(data_dir)
    apply_store = start_apply_store(data_dir, config_store)
    delivery = envelope(1)

    assert {:ok, candidate} = ConfigStore.stage(delivery, config_store)
    assert {:admit, :new} = ConfigApplyStore.preflight(delivery, apply_store)

    assert {:ok, _} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, apply_store)

    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 1}, apply_store)

    assert {:ok, %{attempt: %{checkpoint: :before_install}}} =
             ConfigApplyStore.transition(:before_install, %{version: 1}, apply_store)

    stop(apply_store)
    apply_store = start_apply_store(data_dir, config_store)

    assert {:ok, %{runtime_status: :unknown, attempt: %{checkpoint: :unknown}}} =
             ConfigApplyStore.snapshot(apply_store)

    applier = start_applier(config_store, apply_store)

    assert {:ok, %{status: :replay}} = ConfigApplier.apply(delivery, applier)

    assert {:ok,
            %{
              runtime_status: :unconfigured,
              attempt: %{
                status: :failed,
                checkpoint: :complete,
                failure: %{reason: "runtime restarted during config install"}
              }
            }} = ConfigApplyStore.snapshot(apply_store)

    refute_receive {:adapter_call, _, _}
  end

  test "restart deterministically restores a non-provisional Resolved candidate", %{
    data_dir: data_dir
  } do
    {config_store, apply_store, applier} = start_lifecycle(data_dir)
    assert {:ok, %{status: :applied}} = ConfigApplier.apply(envelope(1), applier)
    drain(apply_store)
    flush_adapter_calls()
    stop(applier)

    payload = %{"upstreams" => ["192.0.2.53"], "search_domains" => ["example.test"]}

    delivery =
      envelope(2,
        operation: "netman.resolved.config.update",
        payload: payload,
        expected_revision: @revision
      )

    assert {:ok, candidate} = ConfigStore.stage(delivery, config_store)
    assert {:admit, :new} = ConfigApplyStore.preflight(delivery, apply_store)

    assert {:ok, _} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, apply_store)

    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 2}, apply_store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 2}, apply_store)

    assert {:ok, %{attempt: %{checkpoint: :before_activate}}} =
             ConfigApplyStore.transition(
               :before_activate,
               %{version: 2, installed_revision: @candidate_revision},
               apply_store
             )

    stop(apply_store)
    apply_store = start_apply_store(data_dir, config_store)

    assert {:ok,
            %{
              runtime_status: :unknown,
              attempt: %{checkpoint: :unknown, installed_revision: @candidate_revision}
            }} = ConfigApplyStore.snapshot(apply_store)

    restarted = start_applier(config_store, apply_store)

    assert_receive {:adapter_call, :restore_config, [{:candidate, @candidate_revision}]}
    assert_receive {:adapter_call, :activate_config, [@revision]}

    assert {:ok,
            %{
              runtime_status: :known,
              known_good: %{version: 1, revision: @revision},
              attempt: %{
                version: 2,
                status: :failed,
                checkpoint: :complete,
                failure: %{
                  phase: :apply,
                  reason: "runtime restarted during config activation"
                },
                rollback: %{status: :succeeded, restored_revision: @revision}
              }
            }} = ConfigApplyStore.snapshot(apply_store)

    assert {:ok, %{status: :replay}} = ConfigApplier.apply(delivery, restarted)
    drain(apply_store)

    next =
      envelope(3,
        payload: %{"profiles" => [classification_profile("next")]},
        expected_revision: @revision
      )

    assert {:admit, :new} = ConfigApplyStore.preflight(next, apply_store)
  end

  test "restart restores a first non-provisional Resolved candidate and admits its successor", %{
    data_dir: data_dir
  } do
    config_store = start_config_store(data_dir)
    apply_store = start_apply_store(data_dir, config_store)
    payload = %{"upstreams" => ["192.0.2.53"], "search_domains" => ["example.test"]}

    delivery =
      envelope(1,
        operation: "netman.resolved.config.update",
        payload: payload
      )

    assert {:ok, candidate} = ConfigStore.stage(delivery, config_store)
    assert {:admit, :new} = ConfigApplyStore.preflight(delivery, apply_store)

    assert {:ok, _} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, apply_store)

    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 1}, apply_store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 1}, apply_store)

    assert {:ok, %{attempt: %{checkpoint: :before_activate}}} =
             ConfigApplyStore.transition(
               :before_activate,
               %{version: 1, installed_revision: @candidate_revision},
               apply_store
             )

    stop(apply_store)
    apply_store = start_apply_store(data_dir, config_store)
    restarted = start_applier(config_store, apply_store)

    assert_receive {:adapter_call, :restore_config, [{:candidate, @candidate_revision}]}
    refute_receive {:adapter_call, :activate_config, _args}

    assert {:ok,
            %{
              runtime_status: :unconfigured,
              known_good: nil,
              attempt: %{
                version: 1,
                status: :failed,
                checkpoint: :complete,
                failure: %{
                  phase: :apply,
                  reason: "runtime restarted during config activation"
                },
                rollback: nil
              }
            }} = ConfigApplyStore.snapshot(apply_store)

    assert {:ok, %{status: :replay}} = ConfigApplier.apply(delivery, restarted)
    drain(apply_store)

    next =
      envelope(2,
        operation: "netman.resolved.config.update",
        payload: %{"upstreams" => ["192.0.2.54"], "search_domains" => []}
      )

    assert {:admit, :new} = ConfigApplyStore.preflight(next, apply_store)
  end

  test "failure to persist the unknown latch after an install side effect fail-stops", %{
    data_dir: data_dir
  } do
    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      install_config: [
        {:run,
         fn ->
           ConfigApplierTestFileOps.fail_next_two(:rename)
           {:ok, @revision}
         end}
      ]
    })

    {config_store, apply_store, applier} =
      start_lifecycle(data_dir, apply_storage_opts: [file_ops: ConfigApplierTestFileOps])

    monitor = Process.monitor(applier)

    assert {:error, %Error{code: :internal}} = ConfigApplier.apply(envelope(1), applier)

    assert_receive {:DOWN, ^monitor, :process, ^applier,
                    {:config_applier_inconsistent_persistence, :uncertain_after_side_effect}}

    assert Process.alive?(config_store)
    assert Process.alive?(apply_store)
  end

  defp start_lifecycle(data_dir, opts \\ []) do
    config_store = start_config_store(data_dir)
    apply_store = start_apply_store(data_dir, config_store, opts)
    applier = start_applier(config_store, apply_store, opts)
    {config_store, apply_store, applier}
  end

  defp start_config_store(data_dir) do
    {:ok, store} =
      ConfigStore.start_link(name: nil, data_dir: data_dir, netman_id: @netman_id)

    store
  end

  defp start_apply_store(data_dir, config_store, opts \\ []) do
    {:ok, store} =
      ConfigApplyStore.start_link(
        name: nil,
        data_dir: data_dir,
        netman_id: @netman_id,
        config_store: config_store,
        storage_opts: Keyword.get(opts, :apply_storage_opts, [])
      )

    store
  end

  defp start_applier(config_store, apply_store, opts \\ []) do
    {:ok, applier} =
      ConfigApplier.start_link(
        name: nil,
        netman_id: @netman_id,
        config_store: config_store,
        config_apply_store: apply_store,
        runtime_adapter: ConfigApplierTestAdapter,
        adapter_timeout: Keyword.get(opts, :adapter_timeout, 30_000)
      )

    applier
  end

  defp envelope(version, opts \\ []) do
    operation = Keyword.get(opts, :operation, @operation)
    payload = Keyword.get(opts, :payload, %{"profiles" => []})
    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: uuid(version),
      target_type: :netman,
      target_id: Keyword.get(opts, :target_id, @netman_id),
      operation: operation,
      idempotency_key: uuid(version + 100),
      payload: payload,
      payload_digest: digest,
      expected_revision: Keyword.get(opts, :expected_revision),
      config_version: version,
      sent_at: ~U[2026-08-11 00:00:00Z]
    }
  end

  defp flush_adapter_calls do
    receive do
      {:adapter_call, _, _} -> flush_adapter_calls()
    after
      0 -> :ok
    end
  end

  defp drain(store) do
    {:ok, publications} = ConfigApplyStore.pending_publications(store)

    for publication <- publications do
      assert {:ok, _snapshot} =
               ConfigApplyStore.acknowledge_publication(publication.sequence, store)
    end
  end

  defp stop(server) do
    if is_pid(server) and Process.alive?(server), do: GenServer.stop(server, :normal)
  end

  defp uuid(value),
    do: "00000000-0000-0000-0000-#{value |> Integer.to_string() |> String.pad_leading(12, "0")}"

  defp classification_profile(id \\ "office") do
    %{
      "profile_id" => id,
      "type" => "ethernet",
      "interface" => "eth0",
      "autoconnect" => true,
      "autoconnect_priority" => 0,
      "zone" => "default",
      "ethernet" => %{"mtu" => nil},
      "ipv4" => %{
        "method" => "auto",
        "address" => nil,
        "gateway" => nil,
        "dns" => [],
        "dns_search" => []
      },
      "ipv6" => %{
        "method" => "auto",
        "address" => nil,
        "gateway" => nil,
        "dns" => [],
        "dns_search" => []
      }
    }
  end
end
