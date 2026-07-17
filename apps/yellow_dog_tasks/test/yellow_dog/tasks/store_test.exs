defmodule YellowDog.Tasks.StoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Job
  alias YellowDog.Tasks.Store
  alias YellowDog.Tasks.TaskStatus
  alias YellowDog.Store.Backend.Cluster, as: ConcordBackend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend

  defmodule TxnBackend do
    @moduledoc false

    @table :yellow_dog_tasks_store_test_txn_backend

    def reset do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:set, :public, :named_table])
        _ref -> :ets.delete_all_objects(@table)
      end

      :ok
    end

    def get(key, _opts \\ []) do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> {:error, :not_found}
      end
    end

    def txn(%{compare: [compare], success: success_ops}, _opts \\ []) do
      with {:ok, succeeded?} <- compare_matches?(compare) do
        if succeeded?, do: Enum.each(success_ops, &execute/1)
        {:ok, %{succeeded: succeeded?}}
      end
    end

    defp compare_matches?({:exists, key, :==, expected}) when is_boolean(expected) do
      {:ok, :ets.member(@table, key) == expected}
    end

    defp compare_matches?({:value, key, :==, expected}) do
      actual =
        case :ets.lookup(@table, key) do
          [{^key, value}] -> value
          [] -> nil
        end

      {:ok, actual == expected}
    end

    defp compare_matches?(_compare), do: {:error, {:invalid_txn, :unsupported_compare}}

    defp execute({:put, key, value, %{}}), do: :ets.insert(@table, {key, value})
    defp execute({:delete, {:key, key}, %{}}), do: :ets.delete(@table, key)
  end

  defmodule FailingBackend do
    @moduledoc false

    def put_if(_key, _value, _opts), do: {:error, :cluster_not_ready}
    def prefix_scan(_prefix, _opts), do: {:error, :cluster_not_ready}
  end

  setup do
    YellowDog.StoreHelper.setup_store()
    previous_backend = Application.get_env(:yellow_dog_tasks, :store_backend)
    Application.put_env(:yellow_dog_tasks, :store_backend, EtsBackend)
    Store.clear_all()

    on_exit(fn ->
      restore_env(:store_backend, previous_backend)
    end)

    :ok
  end

  test "defaults to Concord-backed task storage" do
    Application.delete_env(:yellow_dog_tasks, :store_backend)

    assert Store.backend() == ConcordBackend
  end

  test "creates and lists jobs through YellowDog.Store" do
    task = DataSync.get_task!(:ip_city)

    assert {:ok, %Job{id: id}} = Store.create_job(task, %{"type" => "city"})
    assert is_binary(id)
    assert {:ok, %Job{id: ^id, state: "available"}} = Store.get_job(:ip_city, id)
    assert [%Job{id: ^id}] = Store.recent_jobs(:ip_city)
  end

  test "scans recent jobs by task key prefix" do
    city_task = DataSync.get_task!(:ip_city)
    mac_task = DataSync.get_task!(:mac)

    assert {:ok, %Job{id: city_id}} = Store.create_job(city_task, %{"type" => "city"})
    assert {:ok, %Job{id: mac_id}} = Store.create_job(mac_task, %{})

    assert [%Job{id: ^city_id}] = Store.recent_jobs(:ip_city)
    assert [%Job{id: ^mac_id}] = Store.recent_jobs(:mac)
  end

  test "uses conditional transitions to prevent double execution" do
    task = DataSync.get_task!(:ip_city)
    assert {:ok, job} = Store.create_job(task, %{"type" => "city"})
    assert {:ok, executing} = Store.mark_executing(job)
    assert {:error, :condition_failed} = Store.mark_executing(job)
    assert {:ok, completed} = Store.mark_completed(executing)
    assert completed.state == "completed"
  end

  test "propagates backend errors from state transitions" do
    Application.put_env(:yellow_dog_tasks, :store_backend, FailingBackend)

    job = %Job{id: "job-1", task_key: :ip_city, state: "available"}

    assert {:error, :cluster_not_ready} = Store.mark_executing(job)
  end

  test "task status reports unavailable when the task ledger cannot be read" do
    Application.put_env(:yellow_dog_tasks, :store_backend, FailingBackend)

    status =
      :ip_city
      |> DataSync.get_task!()
      |> TaskStatus.put_status()

    assert status.status == :unavailable
    assert status.status_error == :cluster_not_ready
    assert status.recent_jobs == []
  end

  test "failed jobs retry until max attempts before discard" do
    task =
      :ip_city
      |> DataSync.get_task!()
      |> Map.put(:max_attempts, 2)

    assert {:ok, job} = Store.create_job(task, %{"type" => "city"})
    assert {:ok, executing} = Store.mark_executing(job)
    assert {:ok, retry} = Store.mark_failed(executing, :offline)

    assert retry.state == "available"
    assert retry.attempt == 1
    assert retry.started_at == nil
    assert retry.discarded_at == nil
    assert length(retry.errors) == 1

    assert {:ok, executing_again} = Store.mark_executing(retry)
    assert {:ok, discarded} = Store.mark_failed(executing_again, :offline)

    assert discarded.state == "discarded"
    assert discarded.attempt == 2
    assert discarded.discarded_at
    assert length(discarded.errors) == 2
  end

  test "task status keeps last success beyond the recent jobs limit" do
    task = DataSync.get_task!(:ip_city)

    assert {:ok, success} = Store.create_job(task, %{"type" => "city"})
    assert {:ok, executing_success} = Store.mark_executing(success)
    assert {:ok, completed} = Store.mark_completed(executing_success)

    Process.sleep(5)

    for _index <- 1..21 do
      failing_task = Map.put(task, :max_attempts, 1)
      assert {:ok, job} = Store.create_job(failing_task, %{"type" => "city"})
      assert {:ok, executing} = Store.mark_executing(job)
      assert {:ok, %Job{state: "discarded"}} = Store.mark_failed(executing, :offline)
    end

    status = TaskStatus.put_status(task)

    assert status.last_success.id == completed.id
    assert status.last_failure.state == "discarded"
    assert length(status.recent_jobs) == 20
    refute Enum.any?(status.recent_jobs, &(&1.id == completed.id))
  end

  test "last job lookup uses terminal time instead of insert time" do
    task = DataSync.get_task!(:ip_city)

    assert {:ok, older_insert} = Store.create_job(task, %{"type" => "city"})
    Process.sleep(5)

    assert {:ok, newer_insert} = Store.create_job(task, %{"type" => "city"})
    assert {:ok, newer_executing} = Store.mark_executing(newer_insert)
    assert {:ok, newer_completed} = Store.mark_completed(newer_executing)

    Process.sleep(5)

    assert {:ok, older_executing} = Store.mark_executing(older_insert)
    assert {:ok, older_completed} = Store.mark_completed(older_executing)

    assert Store.last_job(:ip_city, ["completed"]).id == older_completed.id
    assert newer_completed.inserted_at == newer_insert.inserted_at
  end

  test "retention does not prune active jobs" do
    task = DataSync.get_task!(:ip_city)
    failing_task = Map.put(task, :max_attempts, 1)

    assert {:ok, active} = Store.create_job(task, %{"type" => "city"})

    for _index <- 1..502 do
      assert {:ok, job} = Store.create_job(failing_task, %{"type" => "city"})
      assert {:ok, executing} = Store.mark_executing(job)
      assert {:ok, %Job{state: "discarded"}} = Store.mark_failed(executing, :offline)
    end

    assert {:ok, %Job{id: active_id, state: "available"}} = Store.get_job(:ip_city, active.id)
    assert active_id == active.id
  end

  test "reserves one scheduled job per task and minute" do
    assert :ok = Store.reserve_schedule(:ip_city, "2026-06-29T03:30Z")
    assert {:error, :condition_failed} = Store.reserve_schedule(:ip_city, "2026-06-29T03:30Z")
    assert :ok = Store.reserve_schedule(:ip_city, "2026-06-29T03:31Z")
  end

  test "concurrent schedule reservations allow one winner per task and minute" do
    parent = self()
    minute_id = "2026-06-29T03:30Z"

    contenders =
      for _index <- 1..24 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:reserve -> Store.reserve_schedule(:ip_city, minute_id))
        end)
      end

    Enum.each(contenders, fn %{pid: pid} -> assert_receive {:ready, ^pid} end)
    Enum.each(contenders, fn %{pid: pid} -> send(pid, :reserve) end)

    results = Task.await_many(contenders, 5_000)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :condition_failed})) == 23
  end

  test "reserves and releases schedules through a txn-capable backend" do
    TxnBackend.reset()
    Application.put_env(:yellow_dog_tasks, :store_backend, TxnBackend)

    assert :ok = Store.reserve_schedule(:ip_city, "2026-06-29T03:30Z")
    assert {:error, :condition_failed} = Store.reserve_schedule(:ip_city, "2026-06-29T03:30Z")
    assert :ok = Store.release_schedule(:ip_city, "2026-06-29T03:30Z")
    assert :ok = Store.reserve_schedule(:ip_city, "2026-06-29T03:30Z")
  end

  defp restore_env(key, nil), do: Application.delete_env(:yellow_dog_tasks, key)
  defp restore_env(key, value), do: Application.put_env(:yellow_dog_tasks, key, value)
end
