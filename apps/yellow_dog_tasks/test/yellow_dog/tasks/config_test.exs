defmodule YellowDog.Tasks.ConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.Tasks.Config

  setup do
    previous_yellow_dog_data_dir = Application.get_env(:yellow_dog, :data_dir)
    previous_tasks_config = Application.get_env(:yellow_dog_tasks, :tasks_config)

    on_exit(fn ->
      if previous_yellow_dog_data_dir do
        Application.put_env(:yellow_dog, :data_dir, previous_yellow_dog_data_dir)
      else
        Application.delete_env(:yellow_dog, :data_dir)
      end

      if previous_tasks_config do
        Application.put_env(:yellow_dog_tasks, :tasks_config, previous_tasks_config)
      else
        Application.delete_env(:yellow_dog_tasks, :tasks_config)
      end
    end)

    Application.delete_env(:yellow_dog_tasks, :tasks_config)

    :ok
  end

  test "uses a SQLite database under the YellowDog data dir by default" do
    data_dir = Path.join(System.tmp_dir!(), "yellow_dog_tasks_config_test")
    Application.put_env(:yellow_dog, :data_dir, data_dir)

    config = Config.load()

    assert config.enabled?
    assert config.timezone == "Etc/UTC"
    assert Config.database_path(config) == Path.join([data_dir, "tasks", "yellow_dog_tasks.db"])
  end

  test "resolves configured relative database path under the YellowDog data dir" do
    data_dir = Path.join(System.tmp_dir!(), "yellow_dog_tasks_config_test")
    Application.put_env(:yellow_dog, :data_dir, data_dir)
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{"database_path" => "custom/tasks.db"})

    config = Config.load()

    assert Config.database_path(config) == Path.join([data_dir, "custom", "tasks.db"])
  end

  test "uses configured absolute database path unchanged" do
    path = Path.join(System.tmp_dir!(), "yellow_dog_tasks_absolute.db")
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{"database_path" => path})

    config = Config.load()

    assert Config.database_path(config) == path
  end

  test "builds Oban config with Lite engine and one data_sync worker" do
    config = Config.load()
    oban_config = Config.oban_config(config)

    assert oban_config[:engine] == Oban.Engines.Lite
    assert oban_config[:repo] == YellowDog.Tasks.Repo
    assert oban_config[:queues] == [data_sync: 1]
  end

  test "includes the fixed default cron entries" do
    config = Config.load()

    assert [
             {"0 2 * * SUN", YellowDog.Tasks.Workers.SyncRegionDataWorker},
             {"0 3 2 * *", YellowDog.Tasks.Workers.SyncIpDatabaseWorker,
              [args: %{type: "country"}]},
             {"30 3 2 * *", YellowDog.Tasks.Workers.SyncIpDatabaseWorker,
              [args: %{type: "city"}]},
             {"0 4 * * SUN", YellowDog.Tasks.Workers.SyncMacDatabaseWorker}
           ] = cron_entries(config)
  end

  test "ignores user configured worker modules" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{
        "ip_city" => %{
          "worker" => "YellowDog.Tasks.Workers.Untrusted",
          "cron" => "15 1 * * *"
        }
      }
    })

    config = Config.load()

    assert Enum.member?(
             cron_entries(config),
             {"15 1 * * *", YellowDog.Tasks.Workers.SyncIpDatabaseWorker, [args: %{type: "city"}]}
           )

    refute Enum.any?(
             cron_entries(config),
             &(cron_worker(&1) == YellowDog.Tasks.Workers.Untrusted)
           )
  end

  test "omits cron plugin when tasks scheduling is disabled" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{"enabled" => false})

    config = Config.load()

    refute config.enabled?
    refute Enum.any?(Config.oban_config(config)[:plugins], &match?({Oban.Plugins.Cron, _}, &1))
  after
    Application.delete_env(:yellow_dog_tasks, :tasks_config)
  end

  test "rejects invalid cron expressions with a clear error" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"ip_city" => %{"cron" => "60 * * * *"}}
    })

    assert_raise ArgumentError, ~r/tasks.sync.ip_city.cron/, fn ->
      Config.load()
    end
  after
    Application.delete_env(:yellow_dog_tasks, :tasks_config)
  end

  test "rejects unknown sync task keys" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"unknown" => %{"enabled" => true, "cron" => "0 0 * * *"}}
    })

    assert_raise ArgumentError, ~r/tasks.sync contains unknown task key/, fn ->
      Config.load()
    end
  after
    Application.delete_env(:yellow_dog_tasks, :tasks_config)
  end

  defp cron_entries(config) do
    config
    |> Config.oban_config()
    |> Keyword.fetch!(:plugins)
    |> Keyword.fetch!(Oban.Plugins.Cron)
    |> Keyword.fetch!(:crontab)
  end

  defp cron_worker({_cron, worker}), do: worker
  defp cron_worker({_cron, worker, _opts}), do: worker
end
