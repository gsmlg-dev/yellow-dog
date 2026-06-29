defmodule YellowDog.Tasks.StoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Job
  alias YellowDog.Tasks.Store

  setup do
    YellowDog.StoreHelper.setup_store()
    Store.clear_all()
    :ok
  end

  test "creates and lists jobs through YellowDog.Store" do
    task = DataSync.get_task!(:ip_city)

    assert {:ok, %Job{id: id}} = Store.create_job(task, %{"type" => "city"})
    assert {:ok, %Job{id: ^id, state: "available"}} = Store.get_job(id)
    assert [%Job{id: ^id}] = Store.recent_jobs(:ip_city)
  end

  test "uses conditional transitions to prevent double execution" do
    task = DataSync.get_task!(:ip_city)
    assert {:ok, job} = Store.create_job(task, %{"type" => "city"})
    assert {:ok, executing} = Store.mark_executing(job)
    assert {:error, :condition_failed} = Store.mark_executing(job)
    assert {:ok, completed} = Store.mark_completed(executing)
    assert completed.state == "completed"
  end

  test "reserves one scheduled job per task and minute" do
    assert :ok = Store.reserve_schedule(:ip_city, "2026-06-29T03:30Z")
    assert {:error, :condition_failed} = Store.reserve_schedule(:ip_city, "2026-06-29T03:30Z")
    assert :ok = Store.reserve_schedule(:ip_city, "2026-06-29T03:31Z")
  end
end
