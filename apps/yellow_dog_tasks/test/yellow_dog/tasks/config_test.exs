defmodule YellowDog.Tasks.ConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.Tasks.Config

  setup do
    previous_tasks_config = Application.get_env(:yellow_dog_tasks, :tasks_config)

    on_exit(fn ->
      if previous_tasks_config do
        Application.put_env(:yellow_dog_tasks, :tasks_config, previous_tasks_config)
      else
        Application.delete_env(:yellow_dog_tasks, :tasks_config)
      end
    end)

    Application.delete_env(:yellow_dog_tasks, :tasks_config)

    :ok
  end

  test "loads Concord-backed task scheduler defaults" do
    config = Config.load()

    assert config.enabled?
    assert config.timezone == "Etc/UTC"
    assert config.sync["ip_city"]["cron"] == "30 3 2 * *"
    assert config.sync["ip_city"]["max_attempts"] == 3
  end

  test "returns fixed cron entries for enabled tasks" do
    config = Config.load()

    assert [
             {"0 2 * * SUN", :region},
             {"0 3 2 * *", :ip_country},
             {"30 3 2 * *", :ip_city},
             {"0 4 * * SUN", :mac}
           ] = Config.cron_entries(config)
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

    assert Enum.member?(Config.cron_entries(config), {"15 1 * * *", :ip_city})
    refute inspect(Config.cron_entries(config)) =~ "Untrusted"
  end

  test "omits cron entries when task scheduling is disabled" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{"enabled" => false})

    config = Config.load()

    refute config.enabled?
    assert Config.cron_entries(config) == []
  end

  test "rejects invalid cron expressions with a clear error" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"ip_city" => %{"cron" => "60 * * * *"}}
    })

    assert_raise ArgumentError, ~r/tasks.sync.ip_city.cron/, fn ->
      Config.load()
    end
  end

  test "rejects unknown sync task keys" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"unknown" => %{"enabled" => true, "cron" => "0 0 * * *"}}
    })

    assert_raise ArgumentError, ~r/tasks.sync contains unknown task key/, fn ->
      Config.load()
    end
  end
end
