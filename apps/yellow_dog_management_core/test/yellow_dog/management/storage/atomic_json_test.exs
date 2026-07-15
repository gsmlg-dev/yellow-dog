defmodule YellowDog.Management.Storage.AtomicJsonTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath

  setup do
    previous_data_dir = Application.get_env(:yellow_dog_management_core, :data_dir)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-management-json-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)

    on_exit(fn ->
      restore_data_dir(previous_data_dir)
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

  test "replaces a mutable manifest only after complete JSON is synced and closed" do
    assert {:ok, path} = StoragePath.server_manifest("server-01")

    assert {:ok, ^path} = AtomicJson.replace(path, %{"revision" => 1})
    assert {:ok, ^path} = AtomicJson.replace(path, %{"revision" => 2, "state" => "ready"})
    assert {:ok, %{"revision" => 2, "state" => "ready"}} = AtomicJson.read(path)
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
end
