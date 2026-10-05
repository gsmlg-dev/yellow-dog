defmodule YellowDog.Management.TasksTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Plug.Test
  alias YellowDog.Management.{Domain, Repo, TaskDefinition, Web}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "definitions and read-only history truthfully expose disabled and unavailable tasks" do
    assert Enum.map(Domain.list_tasks(), & &1["key"]) == ~w(ip_city ip_country mac)
    assert Enum.all?(Domain.list_tasks(), &(!&1["enabled"]))
    assert {:ok, %{"status" => "unavailable", "available" => false}} = Domain.get_task("mac")
    assert Domain.list_task_history() == []
    assert Domain.list_audit() == []
    assert {:error, %{code: "not_found"}} = Domain.get_task("missing")
  end

  test "schedule edits enforce revision, Boolean and bounded five-field cron" do
    params = %{
      "key" => "ip_city",
      "expected_revision" => 1,
      "enabled" => true,
      "cron" => "*/5 * * * *"
    }

    assert {:ok, %{"revision" => 2, "enabled" => true}} = command("update_task", params)
    assert {:error, %{code: "revision_conflict"}} = command("update_task", params)

    for invalid <- [false, "@daily", "0 0 0 0 0 0", "99 * * * *", String.duplicate("*", 129)] do
      assert {:error, %{code: "invalid_request"}} =
               command("update_task", %{params | "expected_revision" => 2, "cron" => invalid})
    end

    assert {:error, %{code: "invalid_request"}} =
             command("update_task", %{params | "expected_revision" => 2, "enabled" => "true"})

    assert Repo.get!(TaskDefinition, "ip_city").revision == 2
  end

  test "manual run works while disabled, is atomic and idempotent, and active jobs deduplicate" do
    assert {:ok, first} = Domain.mutate("run_task", %{"key" => "ip_city"}, "operator", "once")
    assert {:ok, ^first} = Domain.mutate("run_task", %{"key" => "ip_city"}, "operator", "once")
    assert first["state"] == "available"
    assert first["attempt"] == 0
    assert is_nil(first["result"])
    assert {:ok, second} = command("run_task", %{"key" => "ip_city"})
    assert second["id"] == first["id"]
    assert length(Domain.list_task_jobs("ip_city")) == 1
    assert length(Domain.list_audit()) == 2
    assert {:error, %{code: "unavailable"}} = command("run_task", %{"key" => "mac"})

    assert {:error, %{code: "invalid_request"}} =
             command("run_task", %{"key" => "ip_country", "source_url" => "http://attacker/"})

    assert {:error, %{code: "not_found"}} = command("run_task", %{"key" => "unknown"})
    assert length(Domain.list_task_history()) == 1
  end

  test "scheduler occurrences are due checked and only enqueue once per UTC minute" do
    params = %{
      "key" => "ip_city",
      "expected_revision" => 1,
      "enabled" => true,
      "cron" => "5 4 * * *"
    }

    assert {:ok, _task} = command("update_task", params)
    assert YellowDog.Management.Tasks.due(~U[2026-10-01 04:04:00Z]) == []
    assert [{:ok, first}] = YellowDog.Management.Tasks.due(~U[2026-10-01 04:05:30Z])
    assert [{:ok, ^first}] = YellowDog.Management.Tasks.due(~U[2026-10-01 04:05:59Z])
    assert Repo.aggregate(from(job in Oban.Job, prefix: "management_jobs"), :count) == 1

    assert {:error, %{code: "not_due"}} =
             Domain.mutate(
               "run_task",
               %{"key" => "ip_city", "scheduled_for" => "2026-10-01T04:06:00Z"},
               "scheduler",
               "not-due"
             )
  end

  test "task API reads validate identity and do not mutate" do
    assert Web.call(conn(:get, "/api/tasks"), Web.init([])).status == 200
    assert Web.call(conn(:get, "/api/tasks/ip_city/jobs"), Web.init([])).status == 200
    assert Web.call(conn(:get, "/api/tasks/missing/jobs"), Web.init([])).status == 404
    assert Web.call(conn(:get, "/api/task-history"), Web.init([])).status == 200
    assert Domain.list_audit() == []
  end

  defp command(operation, params),
    do: Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
end
