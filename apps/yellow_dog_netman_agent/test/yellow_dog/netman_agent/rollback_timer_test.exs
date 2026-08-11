defmodule YellowDog.NetmanAgent.RollbackTimerTest do
  use ExUnit.Case, async: false

  Code.require_file("../../support/config_applier_support.ex", __DIR__)
  Code.require_file("../../support/rollback_timer_support.ex", __DIR__)

  alias YellowDog.NetmanAgent.ConfigApplier
  alias YellowDog.NetmanAgent.ConfigApplierTestAdapter
  alias YellowDog.NetmanAgent.ConfigApplyStore
  alias YellowDog.NetmanAgent.ConfigStore
  alias YellowDog.NetmanAgent.RollbackTimer
  alias YellowDog.NetmanAgent.RollbackTimerTestClock
  alias YellowDog.NetmanAgent.RollbackTimerTestTimer
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope

  @netman_id "netman-east-1"
  @first_revision String.duplicate("a", 64)
  @second_revision String.duplicate("b", 64)

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-netman-rollback-timer-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)
    RollbackTimerTestClock.set(1_000_000)
    RollbackTimerTestTimer.configure(self())

    ConfigApplierTestAdapter.configure(self(), %{
      install_config: [{:ok, @first_revision}, {:ok, @second_revision}]
    })

    on_exit(fn ->
      ConfigApplierTestAdapter.clear()
      RollbackTimerTestClock.clear()
      RollbackTimerTestTimer.clear()
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "starts with the production default clock and timer callbacks", %{data_dir: data_dir} do
    assert {:ok, timer} =
             RollbackTimer.start_link(
               name: nil,
               data_dir: data_dir,
               netman_id: @netman_id,
               config_applier: self()
             )

    assert {:ok, %{status: :idle}} = RollbackTimer.snapshot(timer)
    GenServer.stop(timer)
  end

  test "persists an armed deadline across restart and rolls back when it expires", %{
    data_dir: data_dir
  } do
    lifecycle = start_lifecycle(data_dir)
    apply_known_good_then_connectivity_change(lifecycle)

    assert_receive {:rollback_timer_scheduled, timer, deadline_message, 1_000, _ref}
    assert timer == lifecycle.timer

    assert {:ok,
            %{
              status: :armed,
              version: 2,
              previous_revision: @first_revision,
              deadline_unix_ms: 1_001_000
            }} = RollbackTimer.snapshot(lifecycle.timer)

    Enum.each(
      [lifecycle.applier, lifecycle.timer, lifecycle.apply_store, lifecycle.config_store],
      &stop/1
    )

    RollbackTimerTestClock.set(1_000_600)

    restarted = restart_lifecycle(lifecycle)

    assert_receive {:rollback_timer_scheduled, restarted_timer, restarted_message, 400, _ref}
    assert restarted_timer == restarted.timer

    assert {:ok, %{status: :armed, version: 2}} = RollbackTimer.snapshot(restarted.timer)
    send(restarted.timer, restarted_message)

    assert_receive {:adapter_call, :restore_config, [{:candidate, @second_revision}]}
    assert_receive {:adapter_call, :activate_config, [@first_revision]}
    assert {:ok, %{status: :idle}} = RollbackTimer.snapshot(restarted.timer)

    assert {:ok,
            %{
              runtime_status: :known,
              known_good: %{version: 1, revision: @first_revision},
              attempt: %{
                version: 2,
                status: :failed,
                failure: %{phase: :apply, reason: "management reconnect timed out"},
                rollback: %{status: :succeeded, succeeded: true}
              }
            }} = ConfigApplyStore.snapshot(restarted.apply_store)

    assert deadline_message == restarted_message
  end

  test "successful reconnect confirmation cancels rollback and durably marks applied", %{
    data_dir: data_dir
  } do
    lifecycle = start_lifecycle(data_dir)
    apply_known_good_then_connectivity_change(lifecycle)

    assert_receive {:rollback_timer_scheduled, _timer, _message, 1_000, timer_ref}

    assert {:ok, %{status: :applied, publications: publications}} =
             RollbackTimer.confirm(lifecycle.timer)

    assert Enum.map(publications, & &1.message.state) == [:delivered, :applying, :applied]
    assert_receive {:rollback_timer_cancelled, ^timer_ref}
    refute_receive {:adapter_call, :restore_config, _args}

    assert {:ok,
            %{
              runtime_status: :known,
              known_good: %{version: 2, revision: @second_revision},
              attempt: %{status: :applied, checkpoint: :complete}
            }} = ConfigApplyStore.snapshot(lifecycle.apply_store)

    assert {:ok, %{status: :idle}} = RollbackTimer.snapshot(lifecycle.timer)

    stop(lifecycle.timer)
    {:ok, restarted} = start_rollback_timer(lifecycle)
    assert {:ok, %{status: :idle}} = RollbackTimer.snapshot(restarted)
    refute_receive {:rollback_timer_scheduled, ^restarted, _message, _delay, _ref}
  end

  test "timeout rollback failure is durable and bounded", %{data_dir: data_dir} do
    ConfigApplierTestAdapter.clear()

    ConfigApplierTestAdapter.configure(self(), %{
      install_config: [{:ok, @first_revision}, {:ok, @second_revision}],
      restore_config: [{:error, :restore_failed}]
    })

    lifecycle = start_lifecycle(data_dir)
    apply_known_good_then_connectivity_change(lifecycle)
    assert_receive {:rollback_timer_scheduled, timer, deadline_message, 1_000, _ref}

    send(timer, deadline_message)
    assert_receive {:adapter_call, :restore_config, [{:candidate, @second_revision}]}
    assert {:ok, %{status: :idle}} = RollbackTimer.snapshot(timer)

    assert {:ok, publications} = ConfigApplyStore.pending_publications(lifecycle.apply_store)
    assert length(publications) == 3
    assert Enum.map(publications, & &1.message.state) == [:delivered, :applying, :failed]

    failed = List.last(publications).message
    assert failed.failure == %{"phase" => "rollback", "reason" => "config restore failed"}

    assert failed.rollback == %{
             "succeeded" => false,
             "restored_version" => nil,
             "restored_revision" => nil,
             "reason" => "config restore failed"
           }

    assert {:ok, %{runtime_status: :unknown}} =
             ConfigApplyStore.snapshot(lifecycle.apply_store)
  end

  test "non-connectivity changes apply immediately without arming rollback", %{
    data_dir: data_dir
  } do
    lifecycle = start_lifecycle(data_dir)
    first = envelope(1, profile(zone: "blue"))
    second = envelope(2, profile(zone: "red", autoconnect: false, mtu: 1_400), @first_revision)

    assert {:ok, %{status: :applied}} = ConfigApplier.apply(first, lifecycle.applier)
    drain(lifecycle.apply_store)
    flush_adapter_calls()

    assert {:ok, %{status: :applied, publications: publications}} =
             ConfigApplier.apply(second, lifecycle.applier)

    assert Enum.map(publications, & &1.message.state) == [:delivered, :applying, :applied]
    assert {:ok, %{status: :idle}} = RollbackTimer.snapshot(lifecycle.timer)
    refute_receive {:rollback_timer_scheduled, _timer, _message, _delay, _ref}
  end

  defp apply_known_good_then_connectivity_change(lifecycle) do
    first = envelope(1, profile(interface: "eth0"))
    second = envelope(2, profile(interface: "eth1"), @first_revision)

    assert {:ok, %{status: :applied}} = ConfigApplier.apply(first, lifecycle.applier)
    drain(lifecycle.apply_store)
    flush_adapter_calls()

    assert {:ok, %{status: :provisional, publications: publications}} =
             ConfigApplier.apply(second, lifecycle.applier)

    assert Enum.map(publications, & &1.message.state) == [:delivered, :applying]
    assert_receive {:adapter_call, :activate_config, [@second_revision]}
  end

  defp start_lifecycle(data_dir) do
    {:ok, config_store} =
      ConfigStore.start_link(name: nil, data_dir: data_dir, netman_id: @netman_id)

    {:ok, apply_store} =
      ConfigApplyStore.start_link(
        name: nil,
        data_dir: data_dir,
        netman_id: @netman_id,
        config_store: config_store
      )

    timer_name = unique_name(:rollback_timer)
    applier_name = {:global, {ConfigApplier, :netman_id, @netman_id}}

    lifecycle = %{
      data_dir: data_dir,
      config_store: config_store,
      apply_store: apply_store,
      timer_name: timer_name,
      applier_name: applier_name
    }

    {:ok, timer} = start_rollback_timer(lifecycle)

    {:ok, applier} =
      ConfigApplier.start_link(
        name: nil,
        netman_id: @netman_id,
        config_store: config_store,
        config_apply_store: apply_store,
        rollback_timer: timer_name,
        runtime_adapter: ConfigApplierTestAdapter
      )

    on_exit(fn ->
      Enum.each([applier_name, timer_name, apply_store, config_store], &stop/1)
    end)

    Map.merge(lifecycle, %{timer: timer, applier: applier})
  end

  defp start_rollback_timer(lifecycle) do
    RollbackTimer.start_link(
      name: lifecycle.timer_name,
      data_dir: lifecycle.data_dir,
      netman_id: @netman_id,
      config_applier: lifecycle.applier_name,
      rollback_window: 1_000,
      clock: RollbackTimerTestClock,
      timer: RollbackTimerTestTimer
    )
  end

  defp restart_lifecycle(lifecycle) do
    {:ok, config_store} =
      ConfigStore.start_link(name: nil, data_dir: lifecycle.data_dir, netman_id: @netman_id)

    {:ok, apply_store} =
      ConfigApplyStore.start_link(
        name: nil,
        data_dir: lifecycle.data_dir,
        netman_id: @netman_id,
        config_store: config_store
      )

    recovered = %{lifecycle | config_store: config_store, apply_store: apply_store}
    {:ok, timer} = start_rollback_timer(recovered)

    {:ok, applier} =
      ConfigApplier.start_link(
        name: nil,
        netman_id: @netman_id,
        config_store: config_store,
        config_apply_store: apply_store,
        rollback_timer: lifecycle.timer_name,
        runtime_adapter: ConfigApplierTestAdapter
      )

    on_exit(fn -> Enum.each([applier, timer, apply_store, config_store], &stop/1) end)
    %{recovered | timer: timer, applier: applier}
  end

  defp envelope(version, profile, expected_revision \\ nil) do
    payload = %{"profiles" => [profile]}
    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: uuid(version),
      target_type: :netman,
      target_id: @netman_id,
      operation: "netman.profiles.replace",
      idempotency_key: uuid(version + 100),
      payload: payload,
      payload_digest: digest,
      expected_revision: expected_revision,
      config_version: version,
      sent_at: ~U[2026-08-11 00:00:00Z]
    }
  end

  defp profile(opts) do
    %{
      "profile_id" => "office",
      "type" => "ethernet",
      "interface" => Keyword.get(opts, :interface, "eth0"),
      "autoconnect" => Keyword.get(opts, :autoconnect, true),
      "autoconnect_priority" => Keyword.get(opts, :priority, 0),
      "zone" => Keyword.get(opts, :zone, "default"),
      "ethernet" => %{"mtu" => Keyword.get(opts, :mtu)},
      "ipv4" => %{
        "method" => Keyword.get(opts, :ipv4_method, "auto"),
        "address" => Keyword.get(opts, :ipv4_address),
        "gateway" => Keyword.get(opts, :ipv4_gateway),
        "dns" => Keyword.get(opts, :ipv4_dns, []),
        "dns_search" => Keyword.get(opts, :ipv4_dns_search, [])
      },
      "ipv6" => %{
        "method" => Keyword.get(opts, :ipv6_method, "auto"),
        "address" => Keyword.get(opts, :ipv6_address),
        "gateway" => Keyword.get(opts, :ipv6_gateway),
        "dns" => Keyword.get(opts, :ipv6_dns, []),
        "dns_search" => Keyword.get(opts, :ipv6_dns_search, [])
      }
    }
  end

  defp drain(store) do
    {:ok, publications} = ConfigApplyStore.pending_publications(store)

    for publication <- publications do
      assert {:ok, _snapshot} =
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
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.stop(pid, :normal)
      _missing -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp unique_name(tag),
    do: {:global, {__MODULE__, tag, System.unique_integer([:positive])}}

  defp uuid(value),
    do: "00000000-0000-0000-0000-#{value |> Integer.to_string() |> String.pad_leading(12, "0")}"
end
