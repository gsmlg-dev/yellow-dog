defmodule YellowDog.ServerAgent.ConfigApplierTest do
  use ExUnit.Case, async: false

  Code.require_file("../../support/config_applier_support.ex", __DIR__)

  alias YellowDog.ServerAgent.ConfigApplier
  alias YellowDog.ServerAgent.ConfigApplierMissingRestoreAdapter
  alias YellowDog.ServerAgent.ConfigApplierTestAdapter
  alias YellowDog.ServerAgent.ConfigApplierTestApplyStore
  alias YellowDog.ServerAgent.ConfigApplierTestConfigStore
  alias YellowDog.ServerAgent.ConfigApplierTestFileOps
  alias YellowDog.ServerAgent.ConfigApplyStore
  alias YellowDog.ServerAgent.ConfigStore
  alias YellowDog.ServerAgent.RuntimeAdapter
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.ConfigState
  alias YellowDog.Sync.Message.Heartbeat

  @server_id "server-east-1"
  @profile "dns_only"
  @operation "server.settings.update"
  @revision_a String.duplicate("a", 64)
  @revision_b String.duplicate("b", 64)

  setup do
    previous_trap_exit = Process.flag(:trap_exit, true)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-config-applier-#{System.unique_integer([:positive])}"
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

  test "RuntimeAdapter declares exactly the four approved callbacks" do
    assert RuntimeAdapter.behaviour_info(:callbacks) |> Enum.sort() ==
             [
               activate_config: 1,
               install_config: 2,
               restore_config: 1,
               validate_config: 1
             ]
  end

  test "starts only with the strict validated option set", %{data_dir: data_dir} do
    {config_store, apply_store} = start_stores(data_dir)

    assert {:ok, applier} =
             ConfigApplier.start_link(
               name: nil,
               server_id: @server_id,
               profile: :dns_only,
               config_store: config_store,
               config_apply_store: apply_store,
               runtime_adapter: ConfigApplierTestAdapter
             )

    assert ConfigApplier.child_spec(name: :named_applier).id == :named_applier
    stop(applier)

    invalid_options = [
      [server_id: "", profile: @profile],
      [server_id: "../server", profile: @profile],
      [server_id: @server_id, profile: ""],
      [server_id: @server_id, profile: @profile, config_store: :missing],
      [server_id: @server_id, profile: @profile, config_apply_store: :missing],
      [server_id: @server_id, profile: @profile, runtime_adapter: "adapter"],
      [server_id: @server_id, profile: @profile, unknown: true]
    ]

    for opts <- invalid_options do
      opts =
        Keyword.merge(
          [
            name: nil,
            config_store: config_store,
            config_apply_store: apply_store,
            runtime_adapter: ConfigApplierTestAdapter
          ],
          opts
        )

      assert {:error, :invalid_options} = ConfigApplier.start_link(opts)
    end

    duplicate_opts = [
      name: nil,
      server_id: @server_id,
      server_id: @server_id,
      profile: @profile,
      config_store: config_store,
      config_apply_store: apply_store,
      runtime_adapter: ConfigApplierTestAdapter
    ]

    assert {:error, :invalid_options} = ConfigApplier.start_link(duplicate_opts)
  end

  test "one applier owns each resolved apply store across public-name races", %{
    data_dir: data_dir
  } do
    {config_store, apply_store} = start_stores(data_dir)
    names = [unique_name(:applier_a), unique_name(:applier_b)]
    gate = make_ref()

    starters =
      for name <- names do
        Task.async(fn ->
          Process.flag(:trap_exit, true)

          receive do
            {:start, ^gate} ->
              ConfigApplier.start_link(base_applier_opts(config_store, apply_store, name: name))
          end
        end)
      end

    Enum.each(starters, &send(&1.pid, {:start, gate}))
    results = Enum.map(starters, &Task.await/1)
    appliers = for {:ok, pid} <- results, do: pid
    on_exit(fn -> Enum.each(appliers, &stop/1) end)

    assert [winner] = appliers
    assert Enum.count(results, &(&1 == {:error, :config_applier_already_started})) == 1

    assert {:error, :config_applier_already_started} =
             ConfigApplier.start_link(base_applier_opts(config_store, apply_store, name: nil))

    assert {:ok, %{status: :applied}} = ConfigApplier.apply(envelope(1), winner)
    assert_receive {:adapter_call, :validate_config, [_]}
    assert_receive {:adapter_call, :install_config, [_, _]}
    assert_receive {:adapter_call, :activate_config, [_]}
    refute_receive {:adapter_call, _, _}

    stop(winner)

    assert {:ok, replacement} =
             ConfigApplier.start_link(base_applier_opts(config_store, apply_store, name: nil))

    stop(replacement)
  end

  test "a named apply-store restart remains reachable through the configured reference", %{
    data_dir: data_dir
  } do
    config_store_name = unique_name(:restart_config_store)
    apply_store_name = unique_name(:restart_apply_store)

    {:ok, config_store} =
      ConfigStore.start_link(
        name: config_store_name,
        data_dir: data_dir,
        server_id: @server_id,
        profile: @profile
      )

    apply_opts = [
      name: apply_store_name,
      data_dir: data_dir,
      server_id: @server_id,
      profile: @profile,
      config_store: config_store
    ]

    {:ok, first_apply_store} = ConfigApplyStore.start_link(apply_opts)

    {:ok, applier} =
      ConfigApplier.start_link(base_applier_opts(config_store, apply_store_name, name: nil))

    stop(first_apply_store)
    {:ok, restarted_apply_store} = ConfigApplyStore.start_link(apply_opts)

    assert {:ok, %{status: :applied}} = ConfigApplier.apply(envelope(1), applier)
    assert Process.alive?(applier)

    stop(applier)
    stop(restarted_apply_store)
  end

  test "defaults to the literal unavailable production adapter and fails closed", %{
    data_dir: data_dir
  } do
    {config_store, apply_store} = start_stores(data_dir)
    applier = start_applier(config_store, apply_store, runtime_adapter: nil)

    assert {:ok, %{status: :failed, publications: publications}} =
             ConfigApplier.apply(envelope(1), applier)

    assert Enum.map(publications, & &1.message.state) == [:delivered, :failed]

    assert List.last(publications).message.failure == %{
             "phase" => "validation",
             "reason" => "runtime adapter unavailable"
           }

    refute_receive {:adapter_call, _, _}
  end

  test "requires all four adapter callbacks before validation", %{data_dir: data_dir} do
    {config_store, apply_store} = start_stores(data_dir)

    applier =
      start_applier(config_store, apply_store,
        runtime_adapter: ConfigApplierMissingRestoreAdapter
      )

    assert {:ok, %{status: :failed}} = ConfigApplier.apply(envelope(1), applier)
    assert {:ok, snapshot} = ConfigApplyStore.snapshot(apply_store)
    assert snapshot.attempt.failure.reason == "runtime adapter unavailable"
  end

  test "applies in exact callback order with exact install options", %{data_dir: data_dir} do
    {config_store, apply_store} = start_stores(data_dir)
    applier = start_applier(config_store, apply_store)
    delivery = envelope(1)
    digest = delivery.payload_digest

    assert {:ok, %{status: :applied, publications: publications}} =
             ConfigApplier.apply(delivery, applier)

    assert_receive {:adapter_call, :validate_config, [payload]}
    assert payload == delivery.payload

    assert_receive {:adapter_call, :install_config,
                    [
                      ^payload,
                      [
                        version: 1,
                        digest: ^digest,
                        expected_revision: nil,
                        operation: @operation,
                        profile: @profile
                      ]
                    ]}

    assert_receive {:adapter_call, :activate_config, [@revision_a]}
    refute_receive {:adapter_call, _, _}
    assert Enum.map(publications, & &1.message.state) == [:delivered, :applying, :applied]

    assert {:ok, snapshot} = ConfigApplyStore.snapshot(apply_store)
    assert snapshot.known_good.revision == @revision_a
    assert snapshot.attempt.status == :applied
  end

  test "validation errors are durable sanitized failures without side effects", %{
    data_dir: data_dir
  } do
    secret = "/private/config.toml?token=secret"

    for response <- [
          {:error, secret},
          {:raise, secret},
          {:throw, secret},
          {:exit, secret},
          {:ok, secret}
        ] do
      test_dir = Path.join(data_dir, Integer.to_string(:erlang.phash2(response)))
      ConfigApplierTestAdapter.clear()
      ConfigApplierTestAdapter.configure(self(), %{validate_config: [response]})
      {config_store, apply_store} = start_stores(test_dir)
      applier = start_applier(config_store, apply_store)

      assert {:ok, %{status: :failed, publications: publications}} =
               ConfigApplier.apply(envelope(1), applier)

      assert List.last(publications).message.failure == %{
               "phase" => "validation",
               "reason" => "runtime config validation failed"
             }

      refute inspect(publications) =~ secret
      refute_receive {:adapter_call, :install_config, _}
      stop(applier)
    end
  end

  test "invalid installed revisions fail without activation", %{data_dir: data_dir} do
    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      install_config: [{:ok, "not-a-sync-digest"}]
    })

    {config_store, apply_store} = start_stores(data_dir)
    applier = start_applier(config_store, apply_store)

    assert {:ok, %{status: :failed, publications: publications}} =
             ConfigApplier.apply(envelope(1), applier)

    assert List.last(publications).message.failure["reason"] == "config install failed"
    refute_receive {:adapter_call, :activate_config, _}
  end

  test "first install or activation failure records apply failure without rollback", %{
    data_dir: data_dir
  } do
    cases = [
      {:install, %{install_config: [{:error, "secret"}]}},
      {:activate, %{activate_config: [{:error, "secret"}]}}
    ]

    for {name, responses} <- cases do
      test_dir = Path.join(data_dir, Atom.to_string(name))
      ConfigApplierTestAdapter.clear()
      ConfigApplierTestAdapter.configure(self(), responses)
      {config_store, apply_store} = start_stores(test_dir)
      applier = start_applier(config_store, apply_store)

      assert {:ok, %{status: :failed, publications: publications}} =
               ConfigApplier.apply(envelope(1), applier)

      failed = List.last(publications).message
      assert failed.failure["phase"] == "apply"
      assert failed.rollback == nil
      assert failed.previous_version == nil
      refute_receive {:adapter_call, :restore_config, _}
      stop(applier)
    end
  end

  test "install and activation failures restore and reactivate known-good exactly once", %{
    data_dir: data_dir
  } do
    for failure <- [:install_config, :activate_config] do
      test_dir = Path.join(data_dir, Atom.to_string(failure))
      {config_store, apply_store} = start_stores(test_dir)
      applier = start_applier(config_store, apply_store)
      assert {:ok, %{status: :applied}} = ConfigApplier.apply(envelope(1), applier)
      drain(apply_store)
      flush_adapter_calls()

      ConfigApplierTestAdapter.clear()

      ConfigApplierTestAdapter.configure(self(), %{
        install_config:
          if(failure == :install_config,
            do: [{:error, "raw install failure"}],
            else: [{:ok, @revision_b}]
          ),
        activate_config:
          if(failure == :activate_config,
            do: [{:error, "raw activation failure"}, :ok],
            else: [:ok]
          )
      })

      second = envelope(2, expected_revision: @revision_a)

      assert {:ok, %{status: :failed, publications: publications}} =
               ConfigApplier.apply(second, applier)

      assert_receive {:adapter_call, :validate_config, [_]}
      assert_receive {:adapter_call, :install_config, [_, _]}

      if failure == :activate_config do
        assert_receive {:adapter_call, :activate_config, [@revision_b]}
      end

      assert_receive {:adapter_call, :restore_config, [@revision_a]}
      assert_receive {:adapter_call, :activate_config, [@revision_a]}
      refute_receive {:adapter_call, _, _}

      failed = List.last(publications).message
      assert failed.failure["phase"] == "apply"

      assert failed.rollback == %{
               "succeeded" => true,
               "restored_version" => 1,
               "restored_revision" => @revision_a,
               "reason" => nil
             }

      stop(applier)
    end
  end

  test "restore and reactivation failures report truthful rollback failure", %{data_dir: data_dir} do
    failures =
      for callback <- [:restore_config, :reactivate],
          response <- [
            {:error, "private error payload"},
            {:raise, "private raise payload"},
            {:throw, "private throw payload"},
            {:exit, "private exit payload"},
            :malformed
          ],
          do: {callback, response}

    for {failure, response} <- failures do
      test_dir = Path.join(data_dir, Integer.to_string(:erlang.phash2({failure, response})))
      {config_store, apply_store} = start_stores(test_dir)
      applier = start_applier(config_store, apply_store)
      assert {:ok, %{status: :applied}} = ConfigApplier.apply(envelope(1), applier)
      drain(apply_store)
      flush_adapter_calls()
      ConfigApplierTestAdapter.clear()

      ConfigApplierTestAdapter.configure(self(), %{
        install_config: [{:error, "candidate failed"}],
        restore_config: if(failure == :restore_config, do: [response], else: [:ok]),
        activate_config: if(failure == :reactivate, do: [response], else: [:ok])
      })

      assert {:ok, %{status: :failed, publications: publications}} =
               ConfigApplier.apply(envelope(2, expected_revision: @revision_a), applier)

      failed = List.last(publications).message
      assert failed.failure["phase"] == "rollback"
      assert failed.rollback["succeeded"] == false
      assert failed.rollback["restored_version"] == nil
      assert failed.rollback["restored_revision"] == nil

      expected_reason =
        if failure == :restore_config,
          do: "config restore failed",
          else: "config reactivation failed"

      assert failed.rollback["reason"] == expected_reason
      refute inspect(failed) =~ "private"
      stop(applier)
    end
  end

  test "all side-effect adapter exceptions and malformed returns are sanitized", %{
    data_dir: data_dir
  } do
    cases = [
      {:install_config, {:raise, "install /secret"}},
      {:install_config, {:throw, "install token"}},
      {:install_config, {:exit, "install path"}},
      {:install_config, :malformed},
      {:activate_config, {:raise, "activate /secret"}},
      {:activate_config, {:throw, "activate token"}},
      {:activate_config, {:exit, "activate path"}},
      {:activate_config, {:ok, "malformed"}}
    ]

    for {callback, response} <- cases do
      test_dir = Path.join(data_dir, Integer.to_string(:erlang.phash2({callback, response})))
      ConfigApplierTestAdapter.clear()
      ConfigApplierTestAdapter.configure(self(), %{callback => [response]})
      {config_store, apply_store} = start_stores(test_dir)
      applier = start_applier(config_store, apply_store)

      assert {:ok, %{status: :failed, publications: publications}} =
               ConfigApplier.apply(envelope(1), applier)

      failed = List.last(publications).message
      assert failed.failure["phase"] == "apply"
      refute inspect(failed) =~ "secret"
      refute inspect(failed) =~ "token"
      refute inspect(failed) =~ "path"
      stop(applier)
    end
  end

  test "exact terminal duplicate replays pending publications without runtime work", %{
    data_dir: data_dir
  } do
    {config_store, apply_store} = start_stores(data_dir)
    applier = start_applier(config_store, apply_store)
    delivery = envelope(1)

    assert {:ok, %{status: :applied, publications: first}} =
             ConfigApplier.apply(delivery, applier)

    flush_adapter_calls()

    assert {:ok, %{status: :replay, publications: replay}} =
             ConfigApplier.apply(delivery, applier)

    assert replay == first
    refute_receive {:adapter_call, _, _}
  end

  test "failed unconfigured snapshots remain valid for init and exact replay" do
    snapshot =
      attempt_snapshot(:failed, :complete,
        failure: %{phase: :validation, reason: "runtime config validation failed"}
      )

    {:ok, config_store} = ConfigApplierTestConfigStore.start_link(:unused, :unused)

    {:ok, apply_store} =
      ConfigApplierTestApplyStore.start_scripted(snapshot, %{
        preflight: [{:replay, snapshot}]
      })

    applier = start_applier(config_store, apply_store)

    assert {:ok, %{status: :replay, publications: []}} =
             ConfigApplier.apply(envelope(1), applier)

    refute_receive {:adapter_call, _, _}
  end

  test "different candidate conflicts before ConfigStore current advances", %{data_dir: data_dir} do
    {config_store, apply_store} = start_stores(data_dir)
    applier = start_applier(config_store, apply_store)
    first = envelope(1)
    assert {:ok, %{status: :applied}} = ConfigApplier.apply(first, applier)

    assert {:error, %Error{code: :conflict, details: %{}}} =
             ConfigApplier.apply(envelope(2, expected_revision: @revision_a), applier)

    assert {:ok, current} = ConfigStore.current(config_store)
    assert current["version"] == 1
  end

  test "safe staged and before-validate resumes restage exact content and only repeat validation",
       %{
         data_dir: data_dir
       } do
    for checkpoint <- [:staged, :before_validate] do
      test_dir = Path.join(data_dir, Atom.to_string(checkpoint))
      {config_store, apply_store} = start_stores(test_dir)
      delivery = envelope(1)
      assert {:ok, candidate} = ConfigStore.stage(delivery, config_store)

      assert {:ok, _} =
               ConfigApplyStore.transition(:delivered, %{candidate: candidate}, apply_store)

      if checkpoint == :before_validate do
        assert {:ok, _} =
                 ConfigApplyStore.transition(:before_validate, %{version: 1}, apply_store)
      end

      applier = start_applier(config_store, apply_store)
      assert {:ok, %{status: :applied}} = ConfigApplier.apply(delivery, applier)
      assert_receive {:adapter_call, :validate_config, [_]}
      assert_receive {:adapter_call, :install_config, [_, _]}
      assert_receive {:adapter_call, :activate_config, [_]}
      stop(applier)
    end
  end

  test "stage/current mismatch is a typed internal error before delivery" do
    candidate = immutable_document(envelope(1))
    other = %{candidate | "published_at" => "2026-07-17T09:00:00Z"}
    {:ok, config_store} = ConfigApplierTestConfigStore.start_link({:ok, candidate}, {:ok, other})
    {:ok, apply_store} = ConfigApplierTestApplyStore.start_link(initial_snapshot())
    applier = start_applier(config_store, apply_store)

    assert {:error, %Error{code: :internal, message: "internal error", details: %{}}} =
             ConfigApplier.apply(envelope(1), applier)

    refute_receive {:adapter_call, _, _}
  end

  test "malformed init and replay snapshots fail closed without disclosure" do
    delivery = envelope(1)
    candidate = immutable_document(delivery)

    {:ok, config_store} =
      ConfigApplierTestConfigStore.start_link({:ok, candidate}, {:ok, candidate})

    secret = "snapshot /private/token"

    malformed_init = %{
      initial_snapshot()
      | attempt: %{
          version: 1,
          status: :applying,
          checkpoint: :malformed,
          raw: secret
        }
    }

    {:ok, malformed_init_store} =
      ConfigApplierTestApplyStore.start_scripted(initial_snapshot(), %{
        snapshot: [{:ok, malformed_init}]
      })

    init_result =
      ConfigApplier.start_link(base_applier_opts(config_store, malformed_init_store, name: nil))

    assert {:error, {:config_applier_recovery_failed, :state}} = init_result
    refute inspect(init_result) =~ secret

    malformed_replay =
      update_in(applied_snapshot(), [:attempt], &Map.put(&1, :digest, secret))

    {:ok, malformed_replay_store} =
      ConfigApplierTestApplyStore.start_scripted(initial_snapshot(), %{
        preflight: [{:replay, malformed_replay}]
      })

    applier = start_applier(config_store, malformed_replay_store)

    assert_internal(ConfigApplier.apply(delivery, applier))
    assert Process.alive?(applier)
    refute_receive {:adapter_call, _, _}
  end

  test "malformed pre-side-effect transition snapshots return internal before callbacks" do
    delivery = envelope(1)
    candidate = immutable_document(delivery)

    {:ok, config_store} =
      ConfigApplierTestConfigStore.start_link({:ok, candidate}, {:ok, candidate})

    {:ok, apply_store} =
      ConfigApplierTestApplyStore.start_scripted(initial_snapshot(), %{
        {:transition, :delivered} => [
          {:ok, attempt_snapshot(:delivered, :staged)}
        ],
        {:transition, :before_validate} => [
          {:ok, attempt_snapshot(:delivered, :before_validate)}
        ],
        {:transition, :before_install} => [
          {:ok,
           attempt_snapshot(:applying, :before_install)
           |> update_in([:attempt], &Map.delete(&1, :previous))
           |> Map.put(:private, "malformed /private/before-install")}
        ]
      })

    applier = start_applier(config_store, apply_store)

    assert_internal(ConfigApplier.apply(delivery, applier))
    assert_receive {:adapter_call, :validate_config, [_]}
    refute_receive {:adapter_call, :install_config, _}
    assert Process.alive?(applier)
  end

  test "malformed post-side-effect transition snapshots latch unknown without crashing" do
    delivery = envelope(1)
    candidate = immutable_document(delivery)

    {:ok, config_store} =
      ConfigApplierTestConfigStore.start_link({:ok, candidate}, {:ok, candidate})

    unknown =
      attempt_snapshot(:applying, :unknown,
        runtime_status: :unknown,
        installed_revision: @revision_a
      )

    {:ok, apply_store} =
      ConfigApplierTestApplyStore.start_scripted(
        initial_snapshot(),
        apply_transition_replies(
          {:ok, %{applied_snapshot() | known_good: "raw secret"}},
          {:ok, unknown}
        )
      )

    applier = start_applier(config_store, apply_store)

    assert_internal(ConfigApplier.apply(delivery, applier))
    assert_receive {:adapter_call, :validate_config, [_]}
    assert_receive {:adapter_call, :install_config, [_, _]}
    assert_receive {:adapter_call, :activate_config, [@revision_a]}
    assert Process.alive?(applier)
    assert {:ok, ^unknown} = ConfigApplyStore.snapshot(apply_store)
  end

  test "malformed unknown-transition success fail-stops after a side effect" do
    delivery = envelope(1)
    candidate = immutable_document(delivery)

    {:ok, config_store} =
      ConfigApplierTestConfigStore.start_link({:ok, candidate}, {:ok, candidate})

    malformed_unknown =
      attempt_snapshot(:applying, :unknown,
        runtime_status: :known,
        installed_revision: @revision_a
      )

    {:ok, apply_store} =
      ConfigApplierTestApplyStore.start_scripted(
        initial_snapshot(),
        apply_transition_replies(
          {:ok, %{applied_snapshot() | known_good: "malformed applied"}},
          {:ok, malformed_unknown}
        )
      )

    applier = start_applier(config_store, apply_store)
    monitor = Process.monitor(applier)

    assert_internal(ConfigApplier.apply(delivery, applier))

    assert_receive {:DOWN, ^monitor, :process, ^applier,
                    {:config_applier_inconsistent_persistence, :uncertain_after_side_effect}}
  end

  test "malformed pending publications are never exposed" do
    valid = config_state_publication(1)
    second = config_state_publication(2)
    other_target = config_state_publication(1, target_id: "server-west-1")

    heartbeat = %Heartbeat{
      target_type: :server,
      target_id: @server_id,
      observed_at: ~U[2026-07-17 08:00:00Z]
    }

    {:ok, encoded_heartbeat} = Message.encode(heartbeat)
    wrong_type = %{valid | encoded_message: encoded_heartbeat, message: heartbeat}

    malformed_publications = [
      Enum.map(1..4, &config_state_publication/1),
      [%{valid | sequence: 0}],
      [second, valid],
      [valid, %{second | sequence: 3}],
      [Map.put(valid, :unexpected, "secret")],
      [Map.delete(valid, :message)],
      [wrong_type],
      [%{valid | encoded_message: valid.encoded_message <> " "}],
      [%{valid | encoded_message: "raw secret /private/config"}],
      [other_target],
      [%{valid | encoded_message: other_target.encoded_message}]
    ]

    for {publications, index} <- Enum.with_index(malformed_publications) do
      {:ok, config_store} =
        ConfigApplierTestConfigStore.start_link({:error, :unused}, {:error, :unused})

      {:ok, apply_store} =
        ConfigApplierTestApplyStore.start_scripted(initial_snapshot(), %{
          preflight: [{:replay, applied_snapshot()}],
          pending_publications: [{:ok, publications}]
        })

      applier = start_applier(config_store, apply_store)
      response = ConfigApplier.apply(envelope(1), applier)

      assert_internal(response)
      refute inspect(response) =~ "secret"
      assert Process.alive?(applier), "publication case #{index} crashed the applier"
      refute_receive {:adapter_call, _, _}
      stop(applier)
      stop(apply_store)
      stop(config_store)
    end
  end

  test "a transition failure before install prevents the side effect", %{data_dir: data_dir} do
    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      validate_config: [
        {:run,
         fn ->
           ConfigApplierTestFileOps.fail_next(:rename)
           :ok
         end}
      ]
    })

    {config_store, apply_store} = start_stores(data_dir, test_file_ops: true)
    applier = start_applier(config_store, apply_store)

    assert {:error, %Error{code: :internal, details: %{}}} =
             ConfigApplier.apply(envelope(1), applier)

    assert_receive {:adapter_call, :validate_config, [_]}
    refute_receive {:adapter_call, :install_config, _}

    assert {:ok, %{attempt: %{checkpoint: :before_validate}}} =
             ConfigApplyStore.snapshot(apply_store)
  end

  test "a post-install persistence failure durably latches unknown", %{data_dir: data_dir} do
    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      install_config: [
        {:run,
         fn ->
           ConfigApplierTestFileOps.fail_next(:rename)
           {:ok, @revision_a}
         end}
      ]
    })

    {config_store, apply_store} = start_stores(data_dir, test_file_ops: true)
    applier = start_applier(config_store, apply_store)

    assert {:error, %Error{code: :internal, message: "internal error", details: %{}}} =
             ConfigApplier.apply(envelope(1), applier)

    assert {:ok, snapshot} = ConfigApplyStore.snapshot(apply_store)
    assert snapshot.runtime_status == :unknown
    assert snapshot.attempt.checkpoint == :unknown
    refute_receive {:adapter_call, :activate_config, _}
  end

  test "post-activation, restore, and reactivation persistence failures latch unknown", %{
    data_dir: data_dir
  } do
    for callback <- [:activate_candidate, :restore_config, :reactivate] do
      test_dir = Path.join(data_dir, Atom.to_string(callback))
      ConfigApplierTestAdapter.clear()
      ConfigApplierTestAdapter.configure(self())
      {config_store, apply_store} = start_stores(test_dir, test_file_ops: true)
      applier = start_applier(config_store, apply_store)

      if callback == :activate_candidate do
        ConfigApplierTestAdapter.clear()

        ConfigApplierTestAdapter.configure(self(), %{
          activate_config: [
            {:run,
             fn ->
               ConfigApplierTestFileOps.fail_next(:rename)
               :ok
             end}
          ]
        })

        assert {:error, %Error{code: :internal}} =
                 ConfigApplier.apply(envelope(1), applier)
      else
        assert {:ok, %{status: :applied}} = ConfigApplier.apply(envelope(1), applier)
        drain(apply_store)
        flush_adapter_calls()
        ConfigApplierTestAdapter.clear()

        ConfigApplierTestAdapter.configure(self(), %{
          install_config: [{:error, "candidate failed"}],
          restore_config: [
            if(callback == :restore_config,
              do:
                {:run,
                 fn ->
                   ConfigApplierTestFileOps.fail_next(:rename)
                   :ok
                 end},
              else: :ok
            )
          ],
          activate_config: [
            if(callback == :reactivate,
              do:
                {:run,
                 fn ->
                   ConfigApplierTestFileOps.fail_next(:rename)
                   :ok
                 end},
              else: :ok
            )
          ]
        })

        assert {:error, %Error{code: :internal}} =
                 ConfigApplier.apply(envelope(2, expected_revision: @revision_a), applier)
      end

      assert {:ok, snapshot} = ConfigApplyStore.snapshot(apply_store)
      assert snapshot.runtime_status == :unknown
      assert snapshot.attempt.checkpoint == :unknown
      stop(applier)
    end
  end

  test "failure to persist unknown fail-stops the applier", %{data_dir: data_dir} do
    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      install_config: [
        {:run,
         fn ->
           ConfigApplierTestFileOps.fail_next_two(:rename)
           {:ok, @revision_a}
         end}
      ]
    })

    {config_store, apply_store} = start_stores(data_dir, test_file_ops: true)
    applier = start_applier(config_store, apply_store)
    monitor = Process.monitor(applier)

    assert {:error, %Error{code: :internal, details: %{}}} =
             ConfigApplier.apply(envelope(1), applier)

    assert_receive {:DOWN, ^monitor, :process, ^applier,
                    {:config_applier_inconsistent_persistence, :uncertain_after_side_effect}}
  end

  test "init converts an exposed side-effect checkpoint before serving", %{data_dir: data_dir} do
    {config_store, _real_apply_store} = start_stores(data_dir)
    snapshot = side_effect_snapshot()
    {:ok, apply_store} = ConfigApplierTestApplyStore.start_link(snapshot)
    applier = start_applier(config_store, apply_store)

    assert {:ok, recovered} = ConfigApplyStore.snapshot(apply_store)
    assert recovered.attempt.checkpoint == :unknown
    assert recovered.runtime_status == :unknown

    assert {:ok, %{status: :replay, publications: []}} =
             ConfigApplier.apply(envelope(1), applier)

    refute_receive {:adapter_call, _, _}
  end

  test "init fails when an exposed side-effect checkpoint cannot become unknown", %{
    data_dir: data_dir
  } do
    {config_store, _real_apply_store} = start_stores(data_dir)
    {:ok, apply_store} = ConfigApplierTestApplyStore.start_link(side_effect_snapshot(), :error)

    assert {:error, {:config_applier_recovery_failed, :persistence}} =
             ConfigApplier.start_link(base_applier_opts(config_store, apply_store, name: nil))
  end

  test "restart from a real side-effect checkpoint replays unknown without callbacks", %{
    data_dir: data_dir
  } do
    {config_store, apply_store} = start_stores(data_dir)
    delivery = envelope(1)
    assert {:ok, candidate} = ConfigStore.stage(delivery, config_store)

    assert {:ok, _} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, apply_store)

    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 1}, apply_store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 1}, apply_store)
    stop(apply_store)

    apply_store = restart_apply_store(data_dir, config_store)
    applier = start_applier(config_store, apply_store)

    assert {:ok, %{status: :replay, publications: publications}} =
             ConfigApplier.apply(delivery, applier)

    assert Enum.map(publications, & &1.message.state) == [:delivered, :applying]
    refute_receive {:adapter_call, _, _}
  end

  test "concurrent apply calls cannot interleave runtime callbacks", %{data_dir: data_dir} do
    ref = make_ref()
    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      validate_config: [{:block, self(), ref, :ok}]
    })

    {config_store, apply_store} = start_stores(data_dir)
    applier = start_applier(config_store, apply_store)
    delivery = envelope(1)
    first = Task.async(fn -> ConfigApplier.apply(delivery, applier) end)
    assert_receive {:adapter_call, :validate_config, [_]}
    assert_receive {:adapter_blocked, ^ref}
    second = Task.async(fn -> ConfigApplier.apply(delivery, applier) end)
    refute_receive {:adapter_call, :validate_config, _}, 50
    send(applier, {:release_adapter, ref})

    assert {:ok, %{status: :applied}} = Task.await(first)
    assert {:ok, %{status: :replay}} = Task.await(second)
  end

  defp start_stores(data_dir, opts \\ []) do
    File.mkdir_p!(data_dir)
    config_store_name = unique_name(:config_store)

    {:ok, config_store} =
      ConfigStore.start_link(
        name: config_store_name,
        data_dir: data_dir,
        server_id: @server_id,
        profile: @profile
      )

    apply_opts = [
      name: nil,
      data_dir: data_dir,
      server_id: @server_id,
      profile: @profile,
      config_store: config_store
    ]

    apply_opts =
      if Keyword.get(opts, :test_file_ops, false) do
        Keyword.put(apply_opts, :storage_opts, file_ops: ConfigApplierTestFileOps)
      else
        apply_opts
      end

    {:ok, apply_store} = ConfigApplyStore.start_link(apply_opts)
    {config_store, apply_store}
  end

  defp restart_apply_store(data_dir, config_store) do
    {:ok, apply_store} =
      ConfigApplyStore.start_link(
        name: nil,
        data_dir: data_dir,
        server_id: @server_id,
        profile: @profile,
        config_store: config_store
      )

    apply_store
  end

  defp start_applier(config_store, apply_store, opts \\ []) do
    applier_opts = base_applier_opts(config_store, apply_store, name: nil)

    applier_opts =
      case Keyword.fetch(opts, :runtime_adapter) do
        {:ok, nil} -> Keyword.delete(applier_opts, :runtime_adapter)
        {:ok, adapter} -> Keyword.put(applier_opts, :runtime_adapter, adapter)
        :error -> applier_opts
      end

    {:ok, applier} = ConfigApplier.start_link(applier_opts)
    applier
  end

  defp base_applier_opts(config_store, apply_store, opts) do
    Keyword.merge(
      [
        server_id: @server_id,
        profile: @profile,
        config_store: config_store,
        config_apply_store: apply_store,
        runtime_adapter: ConfigApplierTestAdapter
      ],
      opts
    )
  end

  defp envelope(version, opts \\ []) do
    payload =
      Keyword.get(opts, :payload, %{
        "service" => "dns",
        "entries" => [
          %{"key" => "timeout", "value" => %{"type" => "integer", "value" => version}}
        ]
      })

    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: uuid(version),
      target_type: :server,
      target_id: @server_id,
      operation: @operation,
      idempotency_key: uuid(version + 100),
      payload: payload,
      payload_digest: digest,
      expected_revision: Keyword.get(opts, :expected_revision),
      config_version: version,
      sent_at: ~U[2026-07-17 08:00:00Z]
    }
  end

  defp immutable_document(delivery) do
    %{
      "schema_version" => 1,
      "target_type" => "server",
      "target_id" => @server_id,
      "version" => delivery.config_version,
      "operation" => delivery.operation,
      "profile" => @profile,
      "payload" => delivery.payload,
      "digest" => delivery.payload_digest,
      "expected_revision" => delivery.expected_revision,
      "published_at" => DateTime.to_iso8601(delivery.sent_at)
    }
  end

  defp initial_snapshot do
    %{
      schema_version: 1,
      target_type: :server,
      target_id: @server_id,
      known_good: nil,
      runtime_status: :unconfigured,
      attempt: nil,
      observed_at: nil,
      published_through: 0,
      next_publication_sequence: 1,
      outbox: []
    }
  end

  defp side_effect_snapshot do
    %{
      initial_snapshot()
      | runtime_status: :unconfigured,
        attempt: %{
          version: 1,
          digest: envelope(1).payload_digest,
          operation: @operation,
          profile: @profile,
          expected_revision: nil,
          status: :applying,
          checkpoint: :before_install,
          previous: nil,
          installed_revision: nil,
          failure: nil,
          rollback: nil
        }
    }
  end

  defp attempt_snapshot(status, checkpoint, opts \\ []) do
    known_good = Keyword.get(opts, :known_good)

    %{
      initial_snapshot()
      | known_good: known_good,
        runtime_status:
          Keyword.get(
            opts,
            :runtime_status,
            if(is_nil(known_good), do: :unconfigured, else: :known)
          ),
        attempt: %{
          version: 1,
          digest: envelope(1).payload_digest,
          operation: @operation,
          profile: @profile,
          expected_revision: nil,
          status: status,
          checkpoint: checkpoint,
          previous: Keyword.get(opts, :previous),
          installed_revision: Keyword.get(opts, :installed_revision),
          failure: Keyword.get(opts, :failure),
          rollback: Keyword.get(opts, :rollback)
        },
        observed_at: ~U[2026-07-17 08:00:00Z]
    }
  end

  defp applied_snapshot do
    known_good = %{version: 1, digest: envelope(1).payload_digest, revision: @revision_a}

    attempt_snapshot(:applied, :complete,
      known_good: known_good,
      installed_revision: @revision_a
    )
  end

  defp apply_transition_replies(applied_reply, unknown_reply) do
    %{
      {:transition, :delivered} => [
        {:ok, attempt_snapshot(:delivered, :staged)}
      ],
      {:transition, :before_validate} => [
        {:ok, attempt_snapshot(:delivered, :before_validate)}
      ],
      {:transition, :before_install} => [
        {:ok, attempt_snapshot(:applying, :before_install)}
      ],
      {:transition, :before_activate} => [
        {:ok, attempt_snapshot(:applying, :before_activate, installed_revision: @revision_a)}
      ],
      {:transition, :applied} => [applied_reply],
      {:transition, :uncertain_after_side_effect} => [unknown_reply]
    }
  end

  defp config_state_publication(sequence, opts \\ []) do
    message = %ConfigState{
      target_type: :server,
      target_id: Keyword.get(opts, :target_id, @server_id),
      operation: @operation,
      state: :applied,
      version: 1,
      digest: envelope(1).payload_digest,
      applied_revision: @revision_a,
      previous_version: nil,
      previous_revision: nil,
      failure: nil,
      rollback: nil,
      observed_at: ~U[2026-07-17 08:00:00Z]
    }

    {:ok, encoded_message} = Message.encode(message)

    %{
      sequence: sequence,
      encoded_message: encoded_message,
      message: message
    }
  end

  defp assert_internal(response) do
    assert {:error, %Error{code: :internal, message: "internal error", details: %{}}} = response
  end

  defp drain(store) do
    {:ok, publications} = ConfigApplyStore.pending_publications(store)

    for publication <- publications do
      assert {:ok, _} =
               ConfigApplyStore.acknowledge_publication(publication.sequence, store)
    end
  end

  defp flush_adapter_calls do
    receive do
      {:adapter_call, _, _} -> flush_adapter_calls()
    after
      0 -> :ok
    end
  end

  defp stop(server) do
    if is_pid(server) and Process.alive?(server), do: GenServer.stop(server, :normal)
  end

  defp unique_name(prefix),
    do: :"#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp uuid(value),
    do: "00000000-0000-0000-0000-#{value |> Integer.to_string() |> String.pad_leading(12, "0")}"
end
