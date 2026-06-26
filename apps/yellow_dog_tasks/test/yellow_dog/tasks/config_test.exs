defmodule YellowDog.Tasks.ConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.Tasks.Config

  setup do
    previous_yellow_dog_data_dir = Application.get_env(:yellow_dog, :data_dir)

    on_exit(fn ->
      if previous_yellow_dog_data_dir do
        Application.put_env(:yellow_dog, :data_dir, previous_yellow_dog_data_dir)
      else
        Application.delete_env(:yellow_dog, :data_dir)
      end
    end)

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

  test "builds Oban config with Lite engine and one data_sync worker" do
    config = Config.load()
    oban_config = Config.oban_config(config)

    assert oban_config[:engine] == Oban.Engines.Lite
    assert oban_config[:repo] == YellowDog.Tasks.Repo
    assert oban_config[:queues] == [data_sync: 1]
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
end
