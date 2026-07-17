defmodule YellowDog.Tasks.DataSyncTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Tasks
  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Job
  alias YellowDog.Tasks.Runner
  alias YellowDog.Tasks.Store
  alias YellowDog.Tasks.Workers.SyncIpDatabaseWorker
  alias YellowDog.Tasks.Workers.SyncMacDatabaseWorker
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.Provider
  alias YellowDog.Store.Zone

  defmodule ExitWorker do
    @moduledoc false

    def perform(_job), do: exit(:noproc)
  end

  defmodule RaiseWorker do
    @moduledoc false

    def perform(_job), do: raise("boom")
  end

  defmodule RetryFailureWorker do
    @moduledoc false

    def perform(_job), do: {:error, :offline}
  end

  defmodule ReserveThenFailBackend do
    @moduledoc false

    def prefix_scan(_prefix, _opts), do: {:ok, []}

    def put_if(key, reservation, _opts) do
      send(parent!(), {:reserved, key, reservation})
      :ok
    end

    def put(_key, _value, _opts), do: {:error, :cluster_not_ready}

    def get(_key, _opts) do
      {:ok, %{minute_id: Application.fetch_env!(:yellow_dog_tasks, :test_minute_id)}}
    end

    def delete(key) do
      send(parent!(), {:released, key})
      :ok
    end

    defp parent!, do: Application.fetch_env!(:yellow_dog_tasks, :test_parent)
  end

  defmodule ReserveReleaseFailBackend do
    @moduledoc false

    def prefix_scan(_prefix, _opts), do: {:ok, []}

    def put_if(key, reservation, _opts) do
      send(parent!(), {:reserved, key, reservation})
      :ok
    end

    def put(_key, _value, _opts), do: {:error, :cluster_not_ready}

    def get(_key, _opts) do
      {:ok, %{minute_id: Application.fetch_env!(:yellow_dog_tasks, :test_minute_id)}}
    end

    def delete(key) do
      send(parent!(), {:release_failed, key})
      {:error, :timeout}
    end

    defp parent!, do: Application.fetch_env!(:yellow_dog_tasks, :test_parent)
  end

  setup do
    YellowDog.StoreHelper.setup_store()

    previous =
      save_env([
        :ip_database_downloader,
        :ip_database_metadata,
        :ip_database_file_info,
        :tasks_config,
        :config_file_path,
        :cloud_zone_sync_fun,
        :store_backend,
        :task_supervisor,
        :task_starter,
        :test_minute_id,
        :test_parent
      ])

    Application.put_env(:yellow_dog_tasks, :store_backend, EtsBackend)
    Application.delete_env(:yellow_dog_tasks, :tasks_config)
    Application.delete_env(:yellow_dog_tasks, :config_file_path)
    Store.clear_all()

    Application.put_env(:yellow_dog_tasks, :ip_database_downloader, fn
      :city -> {:ok, "/tmp/city.mmdb"}
      :country -> {:ok, "/tmp/country.mmdb"}
    end)

    Application.put_env(:yellow_dog_tasks, :ip_database_metadata, fn _type -> {:ok, %{}} end)

    Application.put_env(:yellow_dog_tasks, :ip_database_file_info, fn _type ->
      {:ok, %{size: 1}}
    end)

    on_exit(fn -> restore_env(previous) end)

    :ok
  end

  test "lists known tasks without accepting arbitrary workers" do
    tasks = Tasks.list_tasks()

    assert Enum.map(tasks, & &1.key) == [:ip_country, :ip_city, :mac]
    assert Enum.all?(tasks, &Map.has_key?(&1, :status))
  end

  test "lists cloud provider zones as hourly sync tasks" do
    zone_name = "cloud-tasks-#{System.unique_integer([:positive])}.example.com"
    create_cloud_zone("default", zone_name, :cloudflare)

    tasks = Tasks.list_tasks()
    key = "cloud_zone:default:#{zone_name}"

    assert [:ip_country, :ip_city, :mac, ^key] = Enum.map(tasks, & &1.key)

    task = Enum.find(tasks, &(&1.key == key))

    assert task.label == "Cloud DNS: #{zone_name}"
    assert task.source == "Cloudflare DNS"
    assert task.cron == "0 * * * *"
    assert task.enabled?
    assert task.args == %{"view_name" => "default", "zone_name" => zone_name}
  end

  test "does not list zones without enabled cloud providers" do
    disabled_zone_name = "cloud-disabled-#{System.unique_integer([:positive])}.example.com"
    plain_zone_name = "plain-#{System.unique_integer([:positive])}.example.com"

    create_cloud_zone("default", disabled_zone_name, :cloudflare, enabled: false)
    :ok = Zone.create_zone("default", plain_zone_name, Zone.default_soa(plain_zone_name))

    task_keys = Tasks.list_tasks() |> Enum.map(& &1.key)

    refute "cloud_zone:default:#{disabled_zone_name}" in task_keys
    refute "cloud_zone:default:#{plain_zone_name}" in task_keys
  end

  test "validates cloud-zone bindings before creating a job" do
    zone_name = "cloud-validate-#{System.unique_integer([:positive])}.example.com"
    create_cloud_zone("default", zone_name, :cloudflare)
    key = "cloud_zone:default:#{zone_name}"

    assert {:error, :not_found} =
             Tasks.enqueue_cloud_zone_sync("default", zone_name, "cloud-main")

    assert [] = Tasks.recent_jobs(key)

    :ok =
      Provider.put_config(%{
        name: "cloud-main",
        type: :cloudflare,
        credentials: %{api_token: "test-token"},
        enabled: false
      })

    assert {:error, :unsupported} =
             Tasks.enqueue_cloud_zone_sync("default", zone_name, "cloud-main")

    assert [] = Tasks.recent_jobs(key)

    assert {:error, :conflict} =
             Tasks.enqueue_cloud_zone_sync("default", zone_name, "different-provider")

    assert [] = Tasks.recent_jobs(key)
  end

  test "does not bypass disabled mirrors or unsupported provider types" do
    disabled_zone = "cloud-disabled-#{System.unique_integer([:positive])}.example.com"
    unsupported_zone = "cloud-unsupported-#{System.unique_integer([:positive])}.example.com"

    create_cloud_zone("default", disabled_zone, :cloudflare, enabled: false)
    create_cloud_zone("default", unsupported_zone, :rfc2136)

    :ok =
      Provider.put_config(%{
        name: "cloud-main",
        type: :cloudflare,
        credentials: %{api_token: "test-token"},
        enabled: true
      })

    assert {:error, :unsupported} =
             Tasks.enqueue_cloud_zone_sync("default", disabled_zone, "cloud-main")

    assert {:error, :unsupported} =
             Tasks.enqueue_cloud_zone_sync("default", unsupported_zone, "cloud-main")

    assert [] = Tasks.recent_jobs("cloud_zone:default:#{disabled_zone}")
    assert [] = Tasks.recent_jobs("cloud_zone:default:#{unsupported_zone}")
  end

  test "concurrent manual cloud-zone commands create distinct durable jobs when disabled" do
    zone_name = "cloud-manual-#{System.unique_integer([:positive])}.example.com"
    create_cloud_zone("default", zone_name, :route53)
    key = "cloud_zone:default:#{zone_name}"

    :ok =
      Provider.put_config(%{
        name: "cloud-main",
        type: :aws,
        credentials: %{},
        enabled: true
      })

    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{key => %{"enabled" => false, "cron" => "0 * * * *", "max_attempts" => 3}}
    })

    parent = self()

    Application.put_env(:yellow_dog_tasks, :task_starter, fn task_key, job_id ->
      assert {:ok, %Job{id: ^job_id, args: %{"force" => true}}} =
               Store.get_job(task_key, job_id)

      send(parent, {:child_started, job_id})
      :ok
    end)

    jobs =
      12
      |> run_concurrently(fn ->
        Tasks.enqueue_cloud_zone_sync("default", zone_name, "cloud-main")
      end)
      |> Enum.map(fn
        {:ok, %Job{} = job} -> job
        other -> flunk("expected accepted cloud sync, got: #{inspect(other)}")
      end)

    job_ids = Enum.map(jobs, & &1.id)

    assert length(Enum.uniq(job_ids)) == 12
    assert MapSet.new(Enum.map(Tasks.recent_jobs(key), & &1.id)) == MapSet.new(job_ids)

    Enum.each(job_ids, fn job_id ->
      assert_receive {:child_started, ^job_id}
      assert {:ok, %Job{id: ^job_id}} = Store.get_job(key, job_id)
    end)
  end

  test "child-start cleanup deletes only the new cloud-zone job" do
    zone_name = "cloud-start-failure-#{System.unique_integer([:positive])}.example.com"
    create_cloud_zone("default", zone_name, :cloudflare)
    key = "cloud_zone:default:#{zone_name}"

    :ok =
      Provider.put_config(%{
        name: "cloud-main",
        type: :cloudflare,
        credentials: %{api_token: "test-token"},
        enabled: true
      })

    Application.put_env(:yellow_dog_tasks, :task_starter, fn _task_key, _job_id -> :ok end)

    assert {:ok, existing} =
             Tasks.enqueue_cloud_zone_sync("default", zone_name, "cloud-main")

    assert {:ok, unrelated} =
             Store.create_job(DataSync.get_task!(:ip_city), %{"type" => "city", "force" => true})

    parent = self()

    Application.put_env(:yellow_dog_tasks, :task_starter, fn task_key, job_id ->
      assert {:ok, %Job{id: ^job_id}} = Store.get_job(task_key, job_id)
      send(parent, {:failed_child_start, task_key, job_id})
      {:error, :child_start_failed}
    end)

    assert {:error, :apply_failed} =
             Tasks.enqueue_cloud_zone_sync("default", zone_name, "cloud-main")

    assert_receive {:failed_child_start, ^key, failed_id}
    assert {:error, :not_found} = Store.get_job(key, failed_id)
    assert {:ok, %Job{id: existing_id}} = Store.get_job(key, existing.id)
    assert {:ok, %Job{id: unrelated_id}} = Store.get_job(:ip_city, unrelated.id)
    assert existing_id == existing.id
    assert unrelated_id == unrelated.id
    assert [%Job{id: only_cloud_job_id}] = Tasks.recent_jobs(key)
    assert only_cloud_job_id == existing.id
  end

  test "updates cloud zone task schedule without creating atoms" do
    zone_name = "cloud-config-#{System.unique_integer([:positive])}.example.com"
    create_cloud_zone("default", zone_name, :route53)
    key = "cloud_zone:default:#{zone_name}"

    assert {:ok, task} =
             Tasks.update_task(key, %{"enabled" => "false", "cron" => "15 * * * *"})

    assert task.key == key
    refute task.enabled?
    assert task.cron == "15 * * * *"

    assert {:ok, stored_schedule} = EtsBackend.get("tasks:config:#{key}", [])
    assert stored_schedule["enabled"] == false
    assert stored_schedule["cron"] == "15 * * * *"
    assert Application.get_env(:yellow_dog_tasks, :tasks_config) == nil
  end

  test "runs due cloud zone schedules" do
    parent = self()
    zone_name = "cloud-schedule-#{System.unique_integer([:positive])}.example.com"
    create_cloud_zone("default", zone_name, :cloudflare)
    key = "cloud_zone:default:#{zone_name}"

    Application.put_env(:yellow_dog_tasks, :cloud_zone_sync_fun, fn view_name,
                                                                    sync_zone_name,
                                                                    opts ->
      send(parent, {:cloud_sync, view_name, sync_zone_name, opts})
      {:ok, %{records_synced: 0}}
    end)

    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "timezone" => "Etc/UTC",
      "sync" => %{
        "ip_city" => %{"enabled" => false},
        "ip_country" => %{"enabled" => false},
        "mac" => %{"enabled" => false}
      }
    })

    assert [%Job{task_key: ^key}] = Runner.run_due_schedules(~U[2026-06-29 02:00:00Z])

    assert_receive {:cloud_sync, "default", ^zone_name, []}, 500

    assert %Job{state: "completed"} = await_recent_job(key, "completed")
  end

  test "enqueues and records a known IP database task in Store" do
    assert {:ok, %Job{worker: SyncIpDatabaseWorker, queue: "data_sync"} = job} =
             Tasks.enqueue(:ip_city)

    assert job.args == %{"type" => "city", "force" => true}
    assert %Job{id: id, state: "completed"} = await_recent_job(:ip_city, "completed")
    assert id == job.id
  end

  test "enqueues a known MAC database task without using SQL storage" do
    previous =
      save_env([
        :mac_database_ensure_started,
        :mac_database_downloader,
        :mac_database_info
      ])

    Application.put_env(:yellow_dog_tasks, :mac_database_ensure_started, fn -> :ok end)

    Application.put_env(:yellow_dog_tasks, :mac_database_downloader, fn ->
      {:ok, "/tmp/manuf.txt"}
    end)

    Application.put_env(:yellow_dog_tasks, :mac_database_info, fn -> %{entry_count: 1} end)

    try do
      assert {:ok, %Job{worker: SyncMacDatabaseWorker}} = Tasks.enqueue("mac")
      assert %Job{state: "completed"} = await_recent_job(:mac, "completed")
    after
      restore_env(previous)
    end
  end

  test "syncs fixed IP database types through explicit atom mapping" do
    parent = self()

    Application.put_env(:yellow_dog_tasks, :ip_database_downloader, fn type ->
      send(parent, {:download, type})
      {:ok, "/tmp/#{type}.mmdb"}
    end)

    assert :ok = DataSync.sync_ip_database("city")
    assert_received {:download, :city}

    assert :ok = DataSync.sync_ip_database("country")
    assert_received {:download, :country}
  end

  test "retries a failed task until a later attempt succeeds" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"ip_city" => %{"max_attempts" => 2}}
    })

    Application.put_env(:yellow_dog_tasks, :ip_database_downloader, fn :city ->
      Agent.get_and_update(attempts, fn
        0 -> {{:error, :offline}, 1}
        count -> {{:ok, "/tmp/city.mmdb"}, count + 1}
      end)
    end)

    assert {:ok, %Job{}} = Tasks.enqueue(:ip_city)

    assert %Job{state: "completed", attempt: 2, errors: [_error]} =
             await_recent_job(:ip_city, "completed")

    assert Agent.get(attempts, & &1) == 2
  end

  test "discards a failed task after max attempts" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"ip_city" => %{"max_attempts" => 2}}
    })

    Application.put_env(:yellow_dog_tasks, :ip_database_downloader, fn :city ->
      {:error, :offline}
    end)

    assert {:ok, %Job{}} = Tasks.enqueue(:ip_city)

    assert %Job{state: "discarded", attempt: 2, errors: [_second, _first]} =
             await_recent_job(:ip_city, "discarded")
  end

  test "records worker exits before re-raising them" do
    task = %{
      key: :ip_city,
      worker: ExitWorker,
      args: %{},
      max_attempts: 1
    }

    assert {:ok, job} = Store.create_job(task, %{})
    assert catch_exit(Runner.run_job(:ip_city, job.id)) == :noproc

    assert [%Job{id: id, state: "discarded", attempt: 1, errors: [_error]}] =
             Store.recent_jobs(:ip_city)

    assert id == job.id
  end

  test "reports retry dispatch failures instead of swallowing them" do
    start_supervised!({Task.Supervisor, name: BlockedTaskSupervisor, max_children: 0})
    Application.put_env(:yellow_dog_tasks, :task_supervisor, BlockedTaskSupervisor)

    task = %{
      key: :ip_city,
      worker: RetryFailureWorker,
      args: %{},
      max_attempts: 2
    }

    assert {:ok, job} = Store.create_job(task, %{})
    assert {:error, :max_children} = Runner.run_job(:ip_city, job.id)

    assert [%Job{id: id, state: "available", attempt: 1, errors: [_error]}] =
             Store.recent_jobs(:ip_city)

    assert id == job.id
  end

  test "reports retry dispatch failures after worker exceptions" do
    start_supervised!({Task.Supervisor, name: BlockedTaskSupervisor, max_children: 0})
    Application.put_env(:yellow_dog_tasks, :task_supervisor, BlockedTaskSupervisor)

    task = %{
      key: :ip_city,
      worker: RaiseWorker,
      args: %{},
      max_attempts: 2
    }

    assert {:ok, job} = Store.create_job(task, %{})
    assert {:error, :max_children} = Runner.run_job(:ip_city, job.id)

    assert [%Job{id: id, state: "available", attempt: 1, errors: [_error]}] =
             Store.recent_jobs(:ip_city)

    assert id == job.id
  end

  test "reports retry dispatch failures after worker exits" do
    start_supervised!({Task.Supervisor, name: BlockedTaskSupervisor, max_children: 0})
    Application.put_env(:yellow_dog_tasks, :task_supervisor, BlockedTaskSupervisor)

    task = %{
      key: :ip_city,
      worker: ExitWorker,
      args: %{},
      max_attempts: 2
    }

    assert {:ok, job} = Store.create_job(task, %{})
    assert {:error, :max_children} = Runner.run_job(:ip_city, job.id)

    assert [%Job{id: id, state: "available", attempt: 1, errors: [_error]}] =
             Store.recent_jobs(:ip_city)

    assert id == job.id
  end

  test "scheduled runs release reservations when enqueue fails" do
    minute_id = "Etc/UTC:2026-06-29T02:00Z"

    Application.put_env(:yellow_dog_tasks, :store_backend, ReserveThenFailBackend)
    Application.put_env(:yellow_dog_tasks, :test_parent, self())
    Application.put_env(:yellow_dog_tasks, :test_minute_id, minute_id)

    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "timezone" => "Etc/UTC",
      "sync" => %{
        "ip_city" => %{"enabled" => true, "cron" => "0 2 * * *"},
        "ip_country" => %{"enabled" => false},
        "mac" => %{"enabled" => false}
      }
    })

    assert [] = Runner.run_due_schedules(~U[2026-06-29 02:00:00Z])

    assert_received {:reserved, "tasks:schedule:ip_city", %{minute_id: ^minute_id}}
    assert_received {:released, "tasks:schedule:ip_city"}
  end

  test "scheduled runs log reservation release failures when enqueue fails" do
    minute_id = "Etc/UTC:2026-06-29T02:00Z"

    Application.put_env(:yellow_dog_tasks, :store_backend, ReserveReleaseFailBackend)
    Application.put_env(:yellow_dog_tasks, :test_parent, self())
    Application.put_env(:yellow_dog_tasks, :test_minute_id, minute_id)

    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "timezone" => "Etc/UTC",
      "sync" => %{
        "ip_city" => %{"enabled" => true, "cron" => "0 2 * * *"},
        "ip_country" => %{"enabled" => false},
        "mac" => %{"enabled" => false}
      }
    })

    log =
      capture_log(fn ->
        assert [] = Runner.run_due_schedules(~U[2026-06-29 02:00:00Z])
      end)

    assert_received {:reserved, "tasks:schedule:ip_city", %{minute_id: ^minute_id}}
    assert_received {:release_failed, "tasks:schedule:ip_city"}
    assert log =~ "Task scheduler failed to release reservation for ip_city: :timeout"
  end

  test "schedules tasks using the configured timezone" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "timezone" => "America/New_York",
      "sync" => %{
        "ip_city" => %{"enabled" => true, "cron" => "0 2 * * *"},
        "ip_country" => %{"enabled" => false},
        "mac" => %{"enabled" => false}
      }
    })

    assert [%Job{task_key: :ip_city}] =
             Runner.run_due_schedules(~U[2026-06-29 06:00:00Z])

    assert %Job{state: "completed"} = await_recent_job(:ip_city, "completed")
    assert [] = Runner.run_due_schedules(~U[2026-06-29 06:00:30Z])
  end

  test "rejects unknown tasks" do
    assert {:error, :unknown_task} = Tasks.enqueue(:unknown)
  end

  defp create_cloud_zone(view_name, zone_name, provider, opts \\ []) do
    cloud_mirror = %{
      enabled: Keyword.get(opts, :enabled, true),
      connector_name: "cloud-main",
      provider: provider,
      zone_id: "",
      direction: :bidirectional,
      conflict_strategy: :local_wins
    }

    :ok =
      Zone.create_zone(view_name, zone_name, Zone.default_soa(zone_name),
        cloud_mirror: cloud_mirror
      )
  end

  defp save_env(keys), do: Map.new(keys, &{&1, Application.get_env(:yellow_dog_tasks, &1)})

  defp run_concurrently(count, fun) do
    parent = self()

    tasks =
      for _index <- 1..count do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:run -> fun.())
        end)
      end

    Enum.each(tasks, fn %{pid: pid} -> assert_receive {:ready, ^pid} end)
    Enum.each(tasks, fn %{pid: pid} -> send(pid, :run) end)
    Task.await_many(tasks, 5_000)
  end

  defp await_recent_job(key, state, attempts_left \\ 25)

  defp await_recent_job(key, state, attempts_left) when attempts_left > 0 do
    case Tasks.recent_jobs(key) do
      [%Job{state: ^state} = job | _jobs] ->
        job

      _jobs ->
        Process.sleep(10)
        await_recent_job(key, state, attempts_left - 1)
    end
  end

  defp await_recent_job(key, state, 0) do
    flunk("expected recent #{key} job to reach #{state}, got: #{inspect(Tasks.recent_jobs(key))}")
  end

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:yellow_dog_tasks, key)
      {key, value} -> Application.put_env(:yellow_dog_tasks, key, value)
    end)
  end
end
