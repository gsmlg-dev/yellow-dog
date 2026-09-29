defmodule YellowDog.Worker.LocalStoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.{ConfigLoader, LocalStore}

  defmodule FailingOps do
    def write_synced(path, bytes) do
      if fail?(:write),
        do: {:error, :enospc},
        else: YellowDog.Worker.FileOps.write_synced(path, bytes)
    end

    def rename(source, target) do
      if fail?(:rename),
        do: {:error, :eacces},
        else: YellowDog.Worker.FileOps.rename(source, target)
    end

    def sync_path(path) do
      case :ets.lookup(:local_store_failures, :fail) do
        [{:fail, :rollback_write}] ->
          :ets.insert(:local_store_failures, [{:fail, false}, {:write, true}])
          {:error, :injected_sync_failure}

        [{:fail, true}] ->
          :ets.insert(:local_store_failures, {:fail, false})
          {:error, :injected_sync_failure}

        _ ->
          YellowDog.Worker.FileOps.sync_path(path)
      end
    end

    defp fail?(key) do
      case :ets.lookup(:local_store_failures, key) do
        [{^key, true}] ->
          :ets.insert(:local_store_failures, {key, false})
          true

        _ ->
          false
      end
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "worker-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "uncertain pointer remains rejected until a durable reconciliation", %{dir: dir} do
    :ets.new(:local_store_failures, [:named_table, :public])
    old = plan()
    new = stopped(old)
    pid = start_supervised!({LocalStore, data_dir: dir, file_ops: FailingOps})
    {:ok, first} = LocalStore.prepare(pid, old)
    assert :ok = LocalStore.commit(pid, first)
    {:ok, second} = LocalStore.prepare(pid, new)
    :ets.insert(:local_store_failures, {:fail, :rollback_write})

    assert {:error, {:commit_uncertain, :injected_sync_failure, :enospc}} =
             LocalStore.commit(pid, second)

    assert {:error, {:commit_uncertain, _, _}} = LocalStore.recover(pid)
    assert {:error, _} = LocalStore.prepare(pid, %{})
    assert {:error, {:commit_uncertain, _, _}} = LocalStore.recover(pid)
    {:ok, restored} = LocalStore.prepare(pid, old)
    assert :ok = LocalStore.commit(pid, restored)
    assert {:ok, ^old} = LocalStore.recover(pid)
    assert LocalStore.status(pid).error == nil
  end

  test "source loader checks target identity and loads shared C0 TOML", %{dir: dir} do
    source = Path.join(dir, "plan.toml")
    File.cp!(fixture(), source)
    assert {:ok, plan} = ConfigLoader.load(source, "edge-01")
    assert plan["worker_id"] == "edge-01"
    assert {:error, [%{code: :worker_id_mismatch}]} = ConfigLoader.load(source, "other")
  end

  test "loader rejects symlinks, traversal, large and malformed nested input", %{dir: dir} do
    source = Path.join(dir, "plan.toml")
    link = Path.join(dir, "linked.toml")
    File.cp!(fixture(), source)
    File.ln_s!(source, link)
    assert {:error, [%{code: :symlink_source}]} = ConfigLoader.load(link, "edge-01")

    assert {:error, [%{code: :path_traversal}]} =
             ConfigLoader.load(Path.join(dir, "../#{Path.basename(dir)}/plan.toml"), "edge-01")

    File.write!(source, :binary.copy("x", 1_048_577))

    assert {:error, [%{code: :invalid_source_or_too_large}]} =
             ConfigLoader.load(source, "edge-01")

    File.write!(source, "x = " <> :binary.copy("[", 33) <> "0" <> :binary.copy("]", 33))
    assert {:error, [_ | _]} = ConfigLoader.load(source, "edge-01")
  end

  test "committed stopped state survives owner restart and second owner is refused", %{dir: dir} do
    Process.flag(:trap_exit, true)
    plan = plan() |> stopped()
    assert {:ok, pid} = LocalStore.start_link(data_dir: dir)
    assert {:error, :directory_locked} = LocalStore.start_link(data_dir: dir)
    assert {:ok, nil} = LocalStore.recover(pid)
    assert {:ok, candidate} = LocalStore.prepare(pid, plan)
    assert :ok = LocalStore.commit(pid, candidate)
    assert {:ok, ^plan} = LocalStore.recover(pid)
    GenServer.stop(pid)
    assert {:ok, pid2} = LocalStore.start_link(data_dir: dir)
    assert {:ok, ^plan} = LocalStore.recover(pid2)
    GenServer.stop(pid2)
  end

  test "a corrupt same-digest snapshot is rewritten from the validated plan", %{dir: dir} do
    plan = plan()
    assert {:ok, pid} = LocalStore.start_link(data_dir: dir)
    assert {:ok, candidate} = LocalStore.prepare(pid, plan)
    assert :ok = LocalStore.commit(pid, candidate)
    snapshot = Path.join([dir, "snapshots", candidate.hash <> ".toml"])
    File.write!(snapshot, "corrupt")
    assert {:ok, repaired} = LocalStore.prepare(pid, plan)
    assert repaired.hash == candidate.hash
    assert :ok = LocalStore.commit(pid, repaired)
    assert {:ok, ^plan} = LocalStore.recover(pid)
    GenServer.stop(pid)
  end

  test "post-rename sync failure restores previous committed pointer", %{dir: dir} do
    :ets.new(:local_store_failures, [:named_table, :public])
    old = plan()
    new = old |> put_in(["revision"], 2) |> stopped()
    assert {:ok, pid} = LocalStore.start_link(data_dir: dir, file_ops: FailingOps)
    assert {:ok, first} = LocalStore.prepare(pid, old)
    assert :ok = LocalStore.commit(pid, first)
    assert {:ok, second} = LocalStore.prepare(pid, new)
    :ets.insert(:local_store_failures, {:fail, true})

    assert {:error, {:commit_failed_restored, :injected_sync_failure}} =
             LocalStore.commit(pid, second)

    assert {:ok, ^old} = LocalStore.recover(pid)
    GenServer.stop(pid)
    assert {:ok, pid2} = LocalStore.start_link(data_dir: dir)
    assert {:ok, ^old} = LocalStore.recover(pid2)
    GenServer.stop(pid2)
  end

  test "write and rename failures retain committed snapshot", %{dir: dir} do
    :ets.new(:local_store_failures, [:named_table, :public])
    old = plan()
    new = old |> put_in(["revision"], 2) |> stopped()
    assert {:ok, pid} = LocalStore.start_link(data_dir: dir, file_ops: FailingOps)
    assert {:ok, first} = LocalStore.prepare(pid, old)
    assert :ok = LocalStore.commit(pid, first)
    :ets.insert(:local_store_failures, {:write, true})
    assert {:error, :enospc} = LocalStore.prepare(pid, new)
    assert {:ok, ^old} = LocalStore.recover(pid)
    assert {:ok, second} = LocalStore.prepare(pid, new)
    :ets.insert(:local_store_failures, {:rename, true})
    assert {:error, :eacces} = LocalStore.commit(pid, second)
    assert {:ok, ^old} = LocalStore.recover(pid)
    GenServer.stop(pid)
  end

  test "staged candidate is not recovered after abrupt store termination", %{dir: dir} do
    Process.flag(:trap_exit, true)
    old = plan()
    new = old |> put_in(["revision"], 2) |> stopped()
    assert {:ok, pid} = LocalStore.start_link(data_dir: dir)
    assert {:ok, first} = LocalStore.prepare(pid, old)
    assert :ok = LocalStore.commit(pid, first)
    assert {:ok, _staged} = LocalStore.prepare(pid, new)
    Process.exit(pid, :kill)
    assert_receive {:EXIT, ^pid, :killed}
    assert {:ok, pid2} = LocalStore.start_link(data_dir: dir)
    assert {:ok, ^old} = LocalStore.recover(pid2)
    GenServer.stop(pid2)
  end

  test "recovery reports previous snapshot if active is corrupt", %{dir: dir} do
    old = plan()
    new = old |> put_in(["revision"], 2) |> stopped()
    assert {:ok, pid} = LocalStore.start_link(data_dir: dir)
    assert {:ok, first} = LocalStore.prepare(pid, old)
    assert :ok = LocalStore.commit(pid, first)
    assert {:ok, second} = LocalStore.prepare(pid, new)
    assert :ok = LocalStore.commit(pid, second)
    File.write!(Path.join([dir, "snapshots", second.hash <> ".toml"]), "corrupt")
    GenServer.stop(pid)
    assert {:ok, pid2} = LocalStore.start_link(data_dir: dir)
    assert {:ok, ^old} = LocalStore.recover(pid2)
    assert %{error: {:recovered_previous, :snapshot_digest_mismatch}} = LocalStore.status(pid2)
    GenServer.stop(pid2)
  end

  defp fixture do
    Path.expand("../../yellow_dog_config_spec/test/fixtures/complete_zone.toml", __DIR__)
  end

  defp plan do
    {:ok, plan} = fixture() |> File.read!() |> ConfigSpec.decode()
    plan
  end

  defp stopped(plan) do
    services = Enum.map(plan["services"], &Map.put(&1, "desired_state", "stopped"))
    %{plan | "services" => services}
  end
end
