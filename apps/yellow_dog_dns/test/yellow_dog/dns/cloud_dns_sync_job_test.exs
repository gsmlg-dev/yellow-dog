defmodule YellowDog.Dns.CloudDnsSyncJobTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias YellowDog.Dns.CloudDnsSyncJob

  setup do
    previous_runner = Application.get_env(:yellow_dog_dns, :cloud_dns_sync_job_runner)

    on_exit(fn ->
      restore_runner(previous_runner)
    end)

    :ok
  end

  test "enqueue delegates work to the configured background runner" do
    parent = self()

    Application.put_env(:yellow_dog_dns, :cloud_dns_sync_job_runner, fn view_name,
                                                                        zone_name,
                                                                        opts ->
      send(parent, {:cloud_dns_sync_enqueued, view_name, zone_name, opts})
      :ok
    end)

    assert :ok = CloudDnsSyncJob.enqueue("default", "gsmlg.net")
    assert_receive {:cloud_dns_sync_enqueued, "default", "gsmlg.net", []}
  end

  test "perform syncs a zone from cloud using string job arguments" do
    parent = self()

    sync_fun = fn view_name, zone_name, opts ->
      send(parent, {:cloud_dns_sync_performed, view_name, zone_name, opts})
      {:ok, %{records_synced: 4, provider: :route53}}
    end

    assert {:ok, %{records_synced: 4, provider: :route53}} =
             CloudDnsSyncJob.perform(
               %{"view_name" => "default", "zone_name" => "gsmlg.net"},
               sync_fun: sync_fun
             )

    assert_receive {:cloud_dns_sync_performed, "default", "gsmlg.net", []}
  end

  test "default runner starts sync work under the task supervisor" do
    parent = self()
    Application.delete_env(:yellow_dog_dns, :cloud_dns_sync_job_runner)

    start_supervised!({Task.Supervisor, name: YellowDog.Dns.CloudDnsSyncJob.TaskSupervisor})

    sync_fun = fn view_name, zone_name, opts ->
      send(parent, {:cloud_dns_sync_started, view_name, zone_name, opts})
      {:ok, %{records_synced: 1}}
    end

    assert :ok =
             CloudDnsSyncJob.enqueue("default", "gsmlg.net",
               sync_fun: sync_fun,
               request_time: ~U[2026-06-24 00:00:00Z]
             )

    assert_receive {:cloud_dns_sync_started, "default", "gsmlg.net",
                    [request_time: ~U[2026-06-24 00:00:00Z]]}
  end

  test "default runner logs sync failure reasons in the message" do
    parent = self()
    Application.delete_env(:yellow_dog_dns, :cloud_dns_sync_job_runner)

    start_supervised!({Task.Supervisor, name: YellowDog.Dns.CloudDnsSyncJob.TaskSupervisor})

    sync_fun = fn view_name, zone_name, _opts ->
      send(parent, {:cloud_dns_sync_started, self(), view_name, zone_name})
      {:error, :route53_access_key_id_missing}
    end

    log =
      capture_log(fn ->
        assert :ok =
                 CloudDnsSyncJob.enqueue("default", "gsmlg.net", sync_fun: sync_fun)

        assert_receive {:cloud_dns_sync_started, task_pid, "default", "gsmlg.net"}
        monitor_ref = Process.monitor(task_pid)
        assert_receive {:DOWN, ^monitor_ref, :process, ^task_pid, :normal}
      end)

    assert log =~ "Cloud DNS sync failed: :route53_access_key_id_missing"
  end

  defp restore_runner(nil),
    do: Application.delete_env(:yellow_dog_dns, :cloud_dns_sync_job_runner)

  defp restore_runner(runner),
    do: Application.put_env(:yellow_dog_dns, :cloud_dns_sync_job_runner, runner)
end
