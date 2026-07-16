defmodule YellowDog.Management.Storage.AtomicJsonTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath

  setup do
    previous_data_dir = Application.get_env(:yellow_dog_management_core, :data_dir)
    previous_file_ops = Application.fetch_env(:yellow_dog_management_core, :atomic_json_file_ops)

    previous_temp_name =
      Application.fetch_env(:yellow_dog_management_core, :atomic_json_temp_name)

    previous_failure = Application.fetch_env(:yellow_dog_management_core, :atomic_json_failure)

    previous_owner =
      Application.fetch_env(:yellow_dog_management_core, :atomic_json_file_ops_owner)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-management-json-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)

    on_exit(fn ->
      restore_data_dir(previous_data_dir)
      restore_env(:atomic_json_file_ops, previous_file_ops)
      restore_env(:atomic_json_temp_name, previous_temp_name)
      restore_env(:atomic_json_failure, previous_failure)
      restore_env(:atomic_json_file_ops_owner, previous_owner)
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "creates immutable JSON once and reports a conflict on a second write" do
    assert {:ok, path} = StoragePath.event("evt-42")
    assert {:ok, ^path} = AtomicJson.create(path, %{"event" => "registered"})
    assert {:ok, %{"event" => "registered"}} = AtomicJson.read(path)
    assert {:error, %{code: :conflict}} = AtomicJson.create(path, %{"event" => "replaced"})
    assert {:ok, %{"event" => "registered"}} = AtomicJson.read(path)
  end

  test "allows exactly one concurrent immutable create" do
    assert {:ok, path} = StoragePath.event("evt-43")

    results =
      1..20
      |> Task.async_stream(
        fn writer -> AtomicJson.create(path, %{"writer" => writer}) end,
        max_concurrency: 20,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert 1 ==
             Enum.count(results, fn
               {:ok, {:ok, ^path}} -> true
               _other -> false
             end)

    assert 19 ==
             Enum.count(results, fn
               {:ok, {:error, %{code: :conflict}}} -> true
               _other -> false
             end)

    assert {:ok, %{"writer" => writer}} = AtomicJson.read(path)
    assert writer in 1..20
  end

  test "stages immutable JSON and promotes it without clobbering an occupied final path" do
    assert {:ok, path} = StoragePath.event("evt-49")

    assert {:ok, staging_path} = AtomicJson.stage(path, %{"writer" => "owned"})
    assert Path.dirname(staging_path) == Path.dirname(path)
    assert String.ends_with?(staging_path, ".stage")
    assert File.exists?(staging_path)
    refute File.exists?(path)

    assert :ok = File.write(path, Jason.encode!(%{"writer" => "external"}), [:exclusive])
    assert {:error, %{code: :conflict}} = AtomicJson.promote(staging_path, path)
    refute File.exists?(staging_path)
    assert {:ok, %{"writer" => "external"}} = AtomicJson.read(path)

    assert {:ok, second_staging_path} = AtomicJson.stage(path, %{"writer" => "owned"})
    assert :ok = File.rm(path)
    assert {:ok, ^path} = AtomicJson.promote(second_staging_path, path)
    refute File.exists?(second_staging_path)
    assert {:ok, %{"writer" => "owned"}} = AtomicJson.read(path)
  end

  test "replaces a mutable manifest only after complete JSON is synced and closed" do
    assert {:ok, path} = StoragePath.server_manifest("server-01")

    assert {:ok, ^path} = AtomicJson.replace(path, %{"revision" => 1})
    assert {:ok, ^path} = AtomicJson.replace(path, %{"revision" => 2, "state" => "ready"})
    assert {:ok, %{"revision" => 2, "state" => "ready"}} = AtomicJson.read(path)
  end

  test "replaces through a caller-known staging path and validates its identity" do
    assert {:ok, path} = StoragePath.server_manifest("server-known-stage")
    assert {:ok, ^path} = AtomicJson.replace(path, %{"revision" => 1})
    staging_path = AtomicJson.staging_path(path)

    assert {:ok, ^path} =
             AtomicJson.replace(
               path,
               %{"revision" => 2},
               staging_path,
               AtomicJson.FileOps
             )

    refute File.exists?(staging_path)
    assert {:ok, %{"revision" => 2}} = AtomicJson.read(path)

    invalid_staging = Path.join(Path.dirname(Path.dirname(path)), ".manifest.json.invalid.stage")

    assert {:error, %{code: :invalid}} =
             AtomicJson.replace(
               path,
               %{"revision" => 3},
               invalid_staging,
               AtomicJson.FileOps
             )

    refute File.exists?(invalid_staging)
    assert {:ok, %{"revision" => 2}} = AtomicJson.read(path)
  end

  test "caller-known replacement cleans staging after write sync close and rename failures" do
    assert {:ok, path} = StoragePath.server_manifest("server-known-stage-failure")
    assert {:ok, ^path} = AtomicJson.replace(path, %{"revision" => 1})

    for failure <- [:write, :sync, :close, :rename] do
      flush_close_notifications()
      inject_file_failure(failure)
      staging_path = AtomicJson.staging_path(path)

      assert {:error, %{code: :internal}} =
               AtomicJson.replace(path, %{"revision" => 2}, staging_path, __MODULE__.FileOps)

      assert_receive {:atomic_json_file_ops, :close, _device}
      refute File.exists?(staging_path)
      assert {:ok, %{"revision" => 1}} = AtomicJson.read(path)
      clear_file_failure()
    end
  end

  test "returns stable errors for missing, corrupt, and unencodable JSON" do
    assert {:ok, missing_path} = StoragePath.event("evt-44")
    assert {:error, %{code: :not_found}} = AtomicJson.read(missing_path)

    assert :ok = File.mkdir_p(Path.dirname(missing_path))
    assert :ok = File.write(missing_path, "{not json")
    assert {:error, %{code: :invalid}} = AtomicJson.read(missing_path)

    assert {:ok, invalid_path} = StoragePath.event("evt-45")
    assert {:error, %{code: :invalid}} = AtomicJson.create(invalid_path, self())
    refute File.exists?(invalid_path)
  end

  test "cleans immutable files and closes descriptors after injected post-open failures" do
    for {failure, event_id} <- [write: "evt-46", sync: "evt-47", close: "evt-48"] do
      flush_close_notifications()
      assert {:ok, path} = StoragePath.event(event_id)
      inject_file_failure(failure)

      assert {:error, %{code: :internal}} = AtomicJson.create(path, %{"event" => "registered"})
      assert_receive {:atomic_json_file_ops, :close, _device}
      refute File.exists?(path)

      clear_file_failure()
      assert {:ok, ^path} = AtomicJson.create(path, %{"event" => "registered"})
      assert {:ok, %{"event" => "registered"}} = AtomicJson.read(path)
    end
  end

  test "preserves mutable targets and cleans temporary files after injected failures" do
    assert {:ok, path} = StoragePath.server_manifest("server-02")
    assert {:ok, ^path} = AtomicJson.replace(path, %{"revision" => 1})

    for failure <- [:write, :sync, :close, :rename] do
      flush_close_notifications()
      inject_file_failure(failure)

      assert {:error, %{code: :internal}} = AtomicJson.replace(path, %{"revision" => 2})
      assert_receive {:atomic_json_file_ops, :close, _device}
      assert {:ok, %{"revision" => 1}} = AtomicJson.read(path)

      assert {:ok, names} = File.ls(Path.dirname(path))
      refute Enum.any?(names, &String.ends_with?(&1, ".tmp"))

      clear_file_failure()
    end
  end

  test "retries deterministic collisions beyond ten stale temporary files" do
    assert {:ok, path} = StoragePath.netman_manifest("netman-02")
    assert :ok = File.mkdir_p(Path.dirname(path))

    counter = :counters.new(1, [])

    Application.put_env(:yellow_dog_management_core, :atomic_json_temp_name, fn target ->
      :counters.add(counter, 1, 1)
      sequence = :counters.get(counter, 1)
      ".#{Path.basename(target)}.forced-#{sequence}.tmp"
    end)

    for sequence <- 1..10 do
      stale_path = Path.join(Path.dirname(path), ".#{Path.basename(path)}.forced-#{sequence}.tmp")
      assert :ok = File.write(stale_path, "{stale")
    end

    assert {:ok, ^path} = AtomicJson.replace(path, %{"revision" => 2})
    assert {:ok, %{"revision" => 2}} = AtomicJson.read(path)

    for sequence <- 1..10 do
      stale_path = Path.join(Path.dirname(path), ".#{Path.basename(path)}.forced-#{sequence}.tmp")
      assert File.exists?(stale_path)
    end
  end

  test "removes a complete temporary file when replacement cannot rename it", %{
    data_dir: data_dir
  } do
    target = Path.join([data_dir, "management", "manifests", "target.json"])
    assert :ok = File.mkdir_p(Path.dirname(target))
    assert :ok = File.mkdir(target)

    assert {:error, %{code: :internal}} = AtomicJson.replace(target, %{"revision" => 1})

    assert {:ok, names} = File.ls(Path.dirname(target))
    refute Enum.any?(names, &String.ends_with?(&1, ".tmp"))
  end

  test "ignores interrupted stale temporary files during reads and replacements" do
    assert {:ok, path} = StoragePath.netman_manifest("netman-01")
    assert {:ok, ^path} = AtomicJson.replace(path, %{"revision" => 1})

    stale_path = Path.join(Path.dirname(path), ".#{Path.basename(path)}.interrupted.tmp")
    assert :ok = File.write(stale_path, "{partial")

    assert {:ok, %{"revision" => 1}} = AtomicJson.read(path)
    assert {:ok, ^path} = AtomicJson.replace(path, %{"revision" => 2})
    assert {:ok, %{"revision" => 2}} = AtomicJson.read(path)
    assert File.exists?(stale_path)
  end

  defp restore_data_dir(nil), do: Application.delete_env(:yellow_dog_management_core, :data_dir)

  defp restore_data_dir(value),
    do: Application.put_env(:yellow_dog_management_core, :data_dir, value)

  defp inject_file_failure(failure) do
    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops, __MODULE__.FileOps)
    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops_owner, self())
    Application.put_env(:yellow_dog_management_core, :atomic_json_failure, failure)
  end

  defp clear_file_failure do
    Application.put_env(:yellow_dog_management_core, :atomic_json_failure, nil)
  end

  defp flush_close_notifications do
    receive do
      {:atomic_json_file_ops, :close, _device} -> flush_close_notifications()
    after
      0 -> :ok
    end
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end

defmodule YellowDog.Management.Storage.AtomicJsonTest.FileOps do
  defdelegate read(path), to: YellowDog.Management.Storage.AtomicJson.FileOps
  defdelegate ls(path), to: YellowDog.Management.Storage.AtomicJson.FileOps
  def open(path), do: :file.open(path, [:write, :exclusive, :binary, :raw])

  def write(device, contents) do
    if failure?(:write), do: {:error, :injected_write}, else: :file.write(device, contents)
  end

  def sync(device) do
    if failure?(:sync), do: {:error, :injected_sync}, else: :file.sync(device)
  end

  def close(device) do
    result = :file.close(device)
    notify_close(device)
    if failure?(:close), do: {:error, :injected_close}, else: result
  end

  def rename(source, target) do
    if failure?(:rename), do: {:error, :injected_rename}, else: :file.rename(source, target)
  end

  def link(source, target), do: :file.make_link(source, target)

  def rm(path), do: File.rm(path)

  defp failure?(failure),
    do: Application.get_env(:yellow_dog_management_core, :atomic_json_failure) == failure

  defp notify_close(device) do
    case Application.get_env(:yellow_dog_management_core, :atomic_json_file_ops_owner) do
      pid when is_pid(pid) -> send(pid, {:atomic_json_file_ops, :close, device})
      _other -> :ok
    end
  end
end
