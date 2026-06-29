defmodule YellowDog.Config.SchemaTaskConfigTest do
  use ExUnit.Case, async: true

  alias YellowDog.Config.Schema

  describe "defaults/0" do
    test "does not include task scheduler defaults" do
      defaults = Schema.defaults()

      refute Map.has_key?(defaults, "tasks")
    end
  end

  describe "minimal/0" do
    test "does not include disabled task scheduler config" do
      minimal = Schema.minimal()

      refute Map.has_key?(minimal, "tasks")
    end
  end

  describe "validate/1" do
    test "rejects invalid task scheduler field shapes" do
      assert {:error, errors} =
               Schema.validate(%{
                 "tasks" => %{
                   "enabled" => "yes",
                   "timezone" => 123,
                   "sync" => %{
                     "ip_city" => %{"cron" => 123},
                     "mac" => %{"enabled" => "true", "max_attempts" => 0}
                   }
                 }
               })

      assert {"tasks.enabled", _} = Enum.find(errors, &(elem(&1, 0) == "tasks.enabled"))
      assert {"tasks.timezone", _} = Enum.find(errors, &(elem(&1, 0) == "tasks.timezone"))

      assert {"tasks.sync.ip_city.cron", _} =
               Enum.find(errors, &(elem(&1, 0) == "tasks.sync.ip_city.cron"))

      assert {"tasks.sync.mac.enabled", _} =
               Enum.find(errors, &(elem(&1, 0) == "tasks.sync.mac.enabled"))

      assert {"tasks.sync.mac.max_attempts", _} =
               Enum.find(errors, &(elem(&1, 0) == "tasks.sync.mac.max_attempts"))
    end

    test "rejects unknown task scheduler sync keys" do
      assert {:error, [{"tasks.sync.unknown", message}]} =
               Schema.validate(%{
                 "tasks" => %{
                   "sync" => %{
                     "unknown" => %{"enabled" => true, "cron" => "0 0 * * *"}
                   }
                 }
               })

      assert message =~ "unknown task"
    end
  end

  describe "section_comments/0" do
    test "does not include tasks section comment" do
      comments = Schema.section_comments()

      refute Map.has_key?(comments, "tasks")
    end
  end
end
