defmodule YellowDog.Tasks.StartupDnsSyncTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Supervisor, as: DnsSupervisor
  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.Zone
  alias YellowDog.Tasks
  alias YellowDog.Tasks.Store

  setup do
    YellowDog.StoreHelper.setup_store()

    previous_backend = Backend.active()

    previous_tasks_env =
      save_env([
        :cloud_zone_sync_fun,
        :config_file_path,
        :store_backend,
        :task_supervisor,
        :tasks_config
      ])

    EtsBackend.create_table()
    Backend.set_active(EtsBackend)
    :ets.delete_all_objects(EtsBackend.table())

    Application.put_env(:yellow_dog_tasks, :store_backend, EtsBackend)
    Application.put_env(:yellow_dog_tasks, :task_supervisor, YellowDog.Tasks.TaskSupervisor)
    Application.delete_env(:yellow_dog_tasks, :config_file_path)
    Application.delete_env(:yellow_dog_tasks, :tasks_config)
    Store.clear_all()

    if Process.whereis(YellowDog.Tasks.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: YellowDog.Tasks.TaskSupervisor})
    end

    stop_dns()

    on_exit(fn ->
      stop_dns()
      Store.clear_all()
      restore_env(previous_tasks_env)
      :ets.delete_all_objects(EtsBackend.table())
      Backend.set_active(previous_backend)
    end)

    :ok
  end

  test "DNS startup enqueues sync jobs for all enabled cloud provider zones" do
    parent = self()

    Application.put_env(:yellow_dog_tasks, :cloud_zone_sync_fun, fn view_name, zone_name, opts ->
      send(parent, {:startup_cloud_sync, view_name, zone_name, opts})
      {:ok, %{records_synced: 0}}
    end)

    cloudflare_zone = "startup-cloudflare-#{System.unique_integer([:positive])}.example.com"
    route53_zone = "startup-route53-#{System.unique_integer([:positive])}.example.com"
    disabled_zone = "startup-disabled-#{System.unique_integer([:positive])}.example.com"
    plain_zone = "startup-plain-#{System.unique_integer([:positive])}.example.com"

    create_cloud_zone("default", cloudflare_zone, :cloudflare)
    create_cloud_zone("edge", route53_zone, :route53)
    create_cloud_zone("default", disabled_zone, :cloudflare, enabled: false)
    assert :ok = Zone.create_zone("default", plain_zone, Zone.default_soa(plain_zone))

    {:ok, _pid} = DnsSupervisor.start_link(port: 0, skip_persistence: true)

    assert_receive {:startup_cloud_sync, "default", ^cloudflare_zone, []}, 1_000
    assert_receive {:startup_cloud_sync, "edge", ^route53_zone, []}, 1_000
    refute_receive {:startup_cloud_sync, _, ^disabled_zone, _}, 100
    refute_receive {:startup_cloud_sync, _, ^plain_zone, _}, 100

    assert %{state: "completed"} =
             await_recent_job("cloud_zone:default:#{cloudflare_zone}", "completed")

    assert %{state: "completed"} =
             await_recent_job("cloud_zone:edge:#{route53_zone}", "completed")

    assert [] = Tasks.recent_jobs("cloud_zone:default:#{disabled_zone}")
    assert [] = Tasks.recent_jobs("cloud_zone:default:#{plain_zone}")
  end

  defp create_cloud_zone(view_name, zone_name, provider, opts \\ []) do
    cloud_mirror = %{
      enabled: Keyword.get(opts, :enabled, true),
      connector_name: Keyword.get(opts, :connector_name, "cloud-main"),
      provider: provider,
      zone_id: "#{zone_name}-id",
      direction: :bidirectional,
      conflict_strategy: :local_wins
    }

    assert :ok =
             Zone.create_zone(view_name, zone_name, Zone.default_soa(zone_name),
               cloud_mirror: cloud_mirror
             )
  end

  defp stop_dns do
    case Process.whereis(YellowDog.Dns) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  defp await_recent_job(key, state, attempts_left \\ 50)

  defp await_recent_job(key, state, attempts_left) when attempts_left > 0 do
    case Tasks.recent_jobs(key) do
      [%{state: ^state} = job | _jobs] ->
        job

      _jobs ->
        Process.sleep(10)
        await_recent_job(key, state, attempts_left - 1)
    end
  end

  defp await_recent_job(key, state, 0) do
    flunk("expected recent #{key} job to reach #{state}, got: #{inspect(Tasks.recent_jobs(key))}")
  end

  defp save_env(keys), do: Map.new(keys, &{&1, Application.get_env(:yellow_dog_tasks, &1)})

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:yellow_dog_tasks, key)
      {key, value} -> Application.put_env(:yellow_dog_tasks, key, value)
    end)
  end
end
