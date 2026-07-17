defmodule YellowDog.DnsProvider.LifecycleTest do
  use ExUnit.Case, async: false

  alias YellowDog.DnsProvider
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
end
