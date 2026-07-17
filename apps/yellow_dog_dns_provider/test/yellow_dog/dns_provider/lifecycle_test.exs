defmodule YellowDog.DnsProvider.LifecycleTest do
  use ExUnit.Case, async: false

  alias YellowDog.DnsProvider
  alias YellowDog.DnsProvider.Config
  alias YellowDog.DnsProvider.ConfigWatcher
  alias YellowDog.DnsProvider.LifecycleFake
  alias YellowDog.DnsProvider.SyncSupervisor
  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.EventBridge
  alias YellowDog.Store.Provider, as: StoreProvider

  setup do
    previous_dependencies = Application.get_env(:yellow_dog_dns_provider, DnsProvider)

    Application.put_env(:yellow_dog_dns_provider, DnsProvider,
      provider_store: LifecycleFake,
      config_watcher: LifecycleFake
    )

    start_supervised!(LifecycleFake)

    on_exit(fn ->
      if previous_dependencies do
        Application.put_env(:yellow_dog_dns_provider, DnsProvider, previous_dependencies)
      else
        Application.delete_env(:yellow_dog_dns_provider, DnsProvider)
      end
    end)

    :ok
  end

  test "fetch_provider preserves owner failures" do
    LifecycleFake.configure(%{responses: %{get_config: [{:error, :owner_unavailable}]}})

    assert {:error, :owner_unavailable} = DnsProvider.fetch_provider("cf-main")
    assert [{:get_config, ["cf-main"]}] = LifecycleFake.take_calls()
  end

  test "fetch_conflict finds a persisted conflict by global ID" do
    conflict = conflict("conflict-global")

    LifecycleFake.configure(%{
      configs: %{
        "cf-main" => provider_config(),
        "route53-main" => provider_config(%{name: "route53-main", type: :route53})
      },
      conflicts: %{"cf-main" => [conflict], "route53-main" => []}
    })

    assert {:ok, ^conflict} = apply(DnsProvider, :fetch_conflict, ["conflict-global"])

    assert [
             {:list_configs, []},
             {:list_conflicts, ["cf-main"]},
             {:list_conflicts, ["route53-main"]}
           ] = LifecycleFake.take_calls()
  end

  test "fetch_conflict rejects duplicate global IDs" do
    duplicate = conflict("conflict-duplicate")

    LifecycleFake.configure(%{
      configs: %{
        "cf-main" => provider_config(),
        "route53-main" => provider_config(%{name: "route53-main", type: :route53})
      },
      conflicts: %{"cf-main" => [duplicate], "route53-main" => [duplicate]}
    })

    assert {:error, :conflict} = apply(DnsProvider, :fetch_conflict, ["conflict-duplicate"])
  end

  test "fetch_conflict preserves Store owner failures" do
    LifecycleFake.configure(%{responses: %{list_configs: [{:error, :owner_unavailable}]}})

    assert {:error, :owner_unavailable} = DnsProvider.fetch_conflict("conflict-unavailable")
    assert [{:list_configs, []}] = LifecycleFake.take_calls()
  end

  test "update restores exact old credentials after apply failure" do
    old = provider_config(%{credentials: %{api_token: "keep-this-secret"}})
    provider_name = old.name

    LifecycleFake.configure(%{
      configs: %{old.name => old},
      responses: %{reconcile: [{:error, :engine_failed}, :ok]}
    })

    assert {:error, :apply_failed} = DnsProvider.update_provider(old.name, %{sync_interval: 600})
    assert %{configs: %{^provider_name => ^old}} = LifecycleFake.snapshot()

    assert [
             {:get_config, ["cf-main"]},
             {:put_config, [candidate]},
             {:reconcile, ["cf-main"]},
             {:put_config, [^old]},
             {:reconcile, ["cf-main"]}
           ] = LifecycleFake.take_calls()

    assert candidate.credentials == old.credentials
    assert candidate.sync_interval == 600
  end

  test "update reports rollback failure when old engine cannot be restored" do
    old = provider_config()
    provider_name = old.name

    LifecycleFake.configure(%{
      configs: %{old.name => old},
      responses: %{reconcile: [{:error, :engine_failed}, {:error, :restore_failed}]}
    })

    assert {:error, :rollback_failed} =
             DnsProvider.update_provider(old.name, %{sync_interval: 600})

    assert %{configs: %{^provider_name => ^old}} = LifecycleFake.snapshot()
  end

  test "delete persists removal before stopping and restores config on apply failure" do
    old = provider_config()
    provider_name = old.name

    LifecycleFake.configure(%{
      configs: %{old.name => old},
      responses: %{reconcile: [{:error, :stop_failed}, :ok]}
    })

    assert {:error, :apply_failed} = DnsProvider.remove_provider(old.name)
    assert %{configs: %{^provider_name => ^old}} = LifecycleFake.snapshot()

    assert [
             {:get_config, ["cf-main"]},
             {:delete_config, ["cf-main"]},
             {:reconcile, ["cf-main"]},
             {:put_config, [^old]},
             {:reconcile, ["cf-main"]}
           ] = LifecycleFake.take_calls()
  end

  test "delete reports rollback failure when the old engine cannot be restored" do
    old = provider_config()

    LifecycleFake.configure(%{
      configs: %{old.name => old},
      responses: %{reconcile: [{:error, :stop_failed}, {:error, :restore_failed}]}
    })

    assert {:error, :rollback_failed} = DnsProvider.remove_provider(old.name)
  end

  test "reconcile is idempotent for an already matching stopped provider" do
    assert :ok = ConfigWatcher.reconcile("missing-provider")
    assert :ok = ConfigWatcher.reconcile("missing-provider")
  end

  test "reconciles canonical Route 53 once across a duplicate Store event" do
    EtsBackend.create_table()
    Backend.set_active(EtsBackend)
    :ets.delete_all_objects(EtsBackend.table())

    ensure_started(EventBridge)
    ensure_started({Registry, keys: :unique, name: YellowDog.DnsProvider.Registry})
    ensure_started(SyncSupervisor)
    watcher = ensure_started(ConfigWatcher)

    config = %{
      name: "route53-main",
      type: :route53,
      credentials: %{access_key_id: "AKIA", secret_access_key: "secret"},
      zones: [],
      sync_interval: 3600,
      conflict_strategy: :local_wins,
      enabled: true
    }

    assert :ok = StoreProvider.put_config(config)
    assert {:ok, pid} = await_engine(config.name)

    assert %{config: %{type: :route53}, provider_module: YellowDog.DnsProvider.Provider.Aws} =
             :sys.get_state(pid)

    send(watcher, {:store_event, %{type: :put, key: "dns:provider:route53-main:config"}})
    :sys.get_state(watcher)

    assert [{^pid, _}] = Registry.lookup(YellowDog.DnsProvider.Registry, config.name)
  end

  test "serializes explicit and event reconciliation through the watcher" do
    name = unique_provider_name("serialized")
    watcher = start_real_runtime(name)
    initial = provider_config(%{name: name})
    candidate = %{initial | sync_interval: 601}

    assert :ok = StoreProvider.put_config(initial)
    drain_store_events(watcher)
    assert :ok = ConfigWatcher.reconcile(name)

    :sys.suspend(watcher)

    task =
      try do
        assert :ok = StoreProvider.put_config(candidate)
        task = Task.async(fn -> ConfigWatcher.reconcile(name) end)

        assert Task.yield(task, 50) == nil
        task
      after
        resume_watcher(watcher)
      end

    assert :ok = Task.await(task, 5_000)

    send(
      watcher,
      {:store_event, %{type: :put, key: "dns:provider:#{name}:config", value: initial}}
    )

    assert :ok = ConfigWatcher.reconcile(name)
    assert_store_matches_engine(name)
  end

  @tag timeout: 120_000
  test "500 sequential real updates all converge to the latest stored config" do
    name = unique_provider_name("stress")
    watcher = start_real_runtime(name)
    initial = provider_config(%{name: name})

    assert :ok = StoreProvider.put_config(initial)
    drain_store_events(watcher)
    assert :ok = ConfigWatcher.reconcile(name)

    results =
      for sync_interval <- 301..800 do
        DnsProvider.update_provider(name, %{sync_interval: sync_interval})
      end

    assert Enum.frequencies(results) == %{ok: 500}

    send(
      watcher,
      {:store_event, %{type: :put, key: "dns:provider:#{name}:config", value: initial}}
    )

    assert :ok = ConfigWatcher.reconcile(name)
    assert {:ok, %{sync_interval: 800}} = StoreProvider.get_config(name)
    assert_store_matches_engine(name)
  end

  test "real apply compensation converges after candidate and rollback events" do
    name = unique_provider_name("rollback")
    watcher = start_real_runtime(name)
    initial = provider_config(%{name: name})

    assert :ok = StoreProvider.put_config(initial)
    drain_store_events(watcher)
    assert :ok = ConfigWatcher.reconcile(name)
    assert {:ok, persisted_initial} = StoreProvider.get_config(name)

    assert {:error, :apply_failed} =
             DnsProvider.update_provider(name, %{credentials: %{}})

    drain_store_events(watcher)

    assert :ok = ConfigWatcher.reconcile(name)
    assert {:ok, ^persisted_initial} = StoreProvider.get_config(name)
    assert_store_matches_engine(name)
  end

  test "watcher absence is bounded and startup reconciles without self-calling" do
    name = unique_provider_name("restart")
    watcher = start_real_runtime(name)
    initial = provider_config(%{name: name})

    assert :ok = StoreProvider.put_config(initial)
    drain_store_events(watcher)
    assert :ok = ConfigWatcher.reconcile(name)
    assert :ok = SyncSupervisor.stop_engine(name)

    supervisor = Process.whereis(YellowDog.DnsProvider.Supervisor)
    assert :ok = Supervisor.terminate_child(supervisor, ConfigWatcher)

    restarted =
      try do
        assert Process.whereis(ConfigWatcher) == nil
        assert ConfigWatcher.reconcile(name) == {:error, :apply_failed}

        case Supervisor.restart_child(supervisor, ConfigWatcher) do
          {:ok, pid} -> pid
          {:ok, pid, _info} -> pid
        end
      after
        if Process.whereis(ConfigWatcher) == nil do
          Supervisor.restart_child(supervisor, ConfigWatcher)
        end
      end

    assert is_pid(restarted)
    assert :ok = ConfigWatcher.reconcile(name)
    assert_store_matches_engine(name)
  end

  defp provider_config(overrides \\ %{}) do
    Map.merge(
      %{
        name: "cf-main",
        type: :cloudflare,
        credentials: %{api_token: "secret"},
        zones: ["example.test"],
        sync_interval: 300,
        conflict_strategy: :local_wins,
        enabled: true
      },
      overrides
    )
  end

  defp conflict(id) do
    %{
      id: id,
      provider_name: "cf-main",
      zone: "example.test",
      owner: "www",
      type: "A",
      local_records: [%{owner: "www", type: "A", ttl: 60, rdata: "192.0.2.1"}],
      remote_records: [%{owner: "www", type: "A", ttl: 60, rdata: "192.0.2.2"}]
    }
  end

  defp await_engine(name, attempts \\ 20)

  defp await_engine(_name, 0), do: {:error, :not_started}

  defp await_engine(name, attempts) do
    case Registry.lookup(YellowDog.DnsProvider.Registry, name) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        Process.sleep(10)
        await_engine(name, attempts - 1)
    end
  end

  defp ensure_started({Registry, _opts} = child_spec) do
    Process.whereis(YellowDog.DnsProvider.Registry) || start_supervised!(child_spec)
  end

  defp ensure_started(module) do
    Process.whereis(module) || start_supervised!(module)
  end

  defp start_real_runtime(name) do
    Application.put_env(:yellow_dog_dns_provider, DnsProvider,
      provider_store: StoreProvider,
      config_watcher: ConfigWatcher
    )

    EtsBackend.create_table()
    Backend.set_active(EtsBackend)

    ensure_started(EventBridge)
    ensure_started({Registry, keys: :unique, name: YellowDog.DnsProvider.Registry})
    ensure_started(SyncSupervisor)
    watcher = ensure_started(ConfigWatcher)

    on_exit(fn ->
      StoreProvider.delete_config(name)

      if Process.whereis(ConfigWatcher) do
        ConfigWatcher.reconcile(name)
      end
    end)

    watcher
  end

  defp assert_store_matches_engine(name) do
    assert {:ok, stored} = StoreProvider.get_config(name)
    assert {:ok, expected} = Config.from_map(stored)
    assert {:ok, pid} = await_engine(name)
    assert %{config: ^expected} = :sys.get_state(pid)
  end

  defp resume_watcher(watcher) do
    if Process.alive?(watcher) do
      :sys.resume(watcher)
    end
  catch
    :exit, _reason -> :ok
  end

  defp drain_store_events(watcher) do
    :sys.get_state(EventBridge)
    :sys.get_state(watcher)
  end

  defp unique_provider_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
