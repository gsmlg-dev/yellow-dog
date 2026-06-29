defmodule YellowDog.Tasks.ConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.Tasks.Config

  setup do
    previous_tasks_config = Application.get_env(:yellow_dog_tasks, :tasks_config)
    previous_config_file_path = Application.get_env(:yellow_dog_tasks, :config_file_path)

    on_exit(fn ->
      if previous_tasks_config do
        Application.put_env(:yellow_dog_tasks, :tasks_config, previous_tasks_config)
      else
        Application.delete_env(:yellow_dog_tasks, :tasks_config)
      end

      if previous_config_file_path do
        Application.put_env(:yellow_dog_tasks, :config_file_path, previous_config_file_path)
      else
        Application.delete_env(:yellow_dog_tasks, :config_file_path)
      end
    end)

    Application.delete_env(:yellow_dog_tasks, :tasks_config)
    Application.delete_env(:yellow_dog_tasks, :config_file_path)

    :ok
  end

  test "loads standalone task scheduler defaults" do
    config = Config.load()

    assert config.enabled?
    assert config.timezone == "Etc/UTC"
    assert config.sync["ip_city"]["cron"] == "30 3 2 * *"
    assert config.sync["ip_city"]["max_attempts"] == 3
  end

  test "loads standalone tasks config file" do
    path =
      Path.join(
        System.tmp_dir!(),
        "yellowdogdns_tasks_config_#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, """
    [tasks]
    enabled = false
    timezone = "Etc/UTC"

    [tasks.sync.ip_city]
    enabled = true
    cron = "5 1 * * *"
    max_attempts = 5
    """)

    on_exit(fn -> File.rm(path) end)

    Application.put_env(:yellow_dog_tasks, :config_file_path, path)

    config = Config.load()

    refute config.enabled?
    assert config.sync["ip_city"]["enabled"]
    assert config.sync["ip_city"]["cron"] == "5 1 * * *"
    assert config.sync["ip_city"]["max_attempts"] == 5
  end

  test "loads quoted cloud zone task config keys" do
    path =
      Path.join(
        System.tmp_dir!(),
        "yellowdogdns_tasks_config_#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, """
    [tasks]
    enabled = true
    timezone = "Etc/UTC"

    [tasks.sync."cloud_zone:default:example.com"]
    enabled = false
    cron = "15 * * * *"
    max_attempts = 3
    """)

    on_exit(fn -> File.rm(path) end)

    Application.put_env(:yellow_dog_tasks, :config_file_path, path)

    config = Config.load()

    assert config.sync["cloud_zone:default:example.com"]["enabled"] == false
    assert config.sync["cloud_zone:default:example.com"]["cron"] == "15 * * * *"
  end

  test "updates task schedules in standalone task config file" do
    path =
      Path.join(
        System.tmp_dir!(),
        "yellowdogdns_tasks_config_#{System.unique_integer([:positive])}.toml"
      )

    on_exit(fn -> File.rm(path) end)

    Application.put_env(:yellow_dog_tasks, :config_file_path, path)

    assert {:ok, config} =
             Config.update_sync_task("cloud_zone:default:example.com", %{
               "enabled" => false,
               "cron" => "20 * * * *"
             })

    assert config.sync["cloud_zone:default:example.com"]["enabled"] == false
    assert config.sync["cloud_zone:default:example.com"]["cron"] == "20 * * * *"

    assert File.read!(path) =~ ~s([tasks.sync."cloud_zone:default:example.com"])

    Application.delete_env(:yellow_dog_tasks, :tasks_config)
    reloaded = Config.load()

    assert reloaded.sync["cloud_zone:default:example.com"]["enabled"] == false
    assert reloaded.sync["cloud_zone:default:example.com"]["cron"] == "20 * * * *"
  end

  test "returns fixed cron entries for enabled tasks" do
    config = Config.load()

    assert [
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

  test "rejects invalid timezone values" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{"timezone" => "No/Such_Zone"})

    assert_raise ArgumentError, ~r/tasks.timezone is invalid/, fn ->
      Config.load()
    end

    Application.put_env(:yellow_dog_tasks, :tasks_config, %{"timezone" => false})

    assert_raise ArgumentError, ~r/tasks.timezone must be a string/, fn ->
      Config.load()
    end
  end

  test "rejects invalid max attempts values" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"ip_city" => %{"max_attempts" => "3"}}
    })

    assert_raise ArgumentError, ~r/tasks.sync.ip_city.max_attempts must be an integer/, fn ->
      Config.load()
    end

    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"ip_city" => %{"max_attempts" => 0}}
    })

    assert_raise ArgumentError,
                 ~r/tasks.sync.ip_city.max_attempts must be greater than or equal to 1/,
                 fn ->
                   Config.load()
                 end
  end

  test "rejects malformed sync config shapes" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{"sync" => false})

    assert_raise ArgumentError, ~r/tasks.sync must be a map/, fn ->
      Config.load()
    end

    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"ip_city" => false}
    })

    assert_raise ArgumentError, ~r/tasks.sync.ip_city must be a map/, fn ->
      Config.load()
    end
  end

  test "allows cloud zone sync task keys and rejects other unknown sync task keys" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{
        "cloud_zone:default:example.com" => %{
          "enabled" => true,
          "cron" => "0 * * * *",
          "max_attempts" => 3
        }
      }
    })

    assert Config.load().sync["cloud_zone:default:example.com"]["cron"] == "0 * * * *"

    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"unknown" => %{"enabled" => true, "cron" => "0 0 * * *"}}
    })

    assert_raise ArgumentError, ~r/tasks.sync contains unknown task key/, fn ->
      Config.load()
    end
  end
end
