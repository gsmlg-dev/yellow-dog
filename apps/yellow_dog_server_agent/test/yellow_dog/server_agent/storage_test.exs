defmodule YellowDog.ServerAgent.StorageTest do
  use ExUnit.Case, async: false

  alias YellowDog.ServerAgent.Storage
  alias YellowDog.ServerAgent.Storage.FileOps
  alias YellowDog.ServerAgent.TestStorageFileOps
  alias YellowDog.Sync.Error

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-server-agent-storage-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)

    on_exit(fn ->
      TestStorageFileOps.clear_failure()
      TestStorageFileOps.clear_capture()
      TestStorageFileOps.clear_returns()
      File.rm_rf(directory)
    end)

    %{directory: directory}
  end

  test "creates and reads an immutable JSON object", %{directory: directory} do
    path = Path.join(directory, "journal.json")
    document = %{"request_id" => "request-1", "status" => "received"}

    assert {:ok, ^path} = Storage.create(path, document)
    assert {:ok, ^document} = Storage.read(path)
  end

  test "enforces max_bytes after an injected successful read" do
    assert {:error, %Error{code: :invalid, details: %{}}} =
             Storage.read("ignored.json",
               max_bytes: 8,
               file_ops: YellowDog.ServerAgent.OversizedSuccessFileOps
             )
  end

  test "returns sanitized missing, corrupt, scalar, and oversized read errors", %{
    directory: directory
  } do
    missing_path = Path.join(directory, "missing.json")
    corrupt_path = Path.join(directory, "corrupt.json")
    scalar_path = Path.join(directory, "scalar.json")
    oversized_path = Path.join(directory, "oversized.json")

    assert {:error, %Error{code: :not_found, details: %{}}} = Storage.read(missing_path)

    File.write!(corrupt_path, "{")
    assert {:error, %Error{code: :invalid, details: %{}}} = Storage.read(corrupt_path)

    File.write!(scalar_path, "[]")
    assert {:error, %Error{code: :invalid, details: %{}}} = Storage.read(scalar_path)

    File.write!(oversized_path, ~s({"value":"abcdef"}))

    assert {:error, %Error{code: :invalid, details: %{}}} =
             Storage.read(oversized_path, max_bytes: 8)
  end

  test "replaces mutable documents without exposing a staged file", %{directory: directory} do
    path = Path.join(directory, "manifest.json")
    previous = %{"revision" => 1}
    replacement = %{"revision" => 2}

    File.write!(path, Jason.encode!(previous))

    assert {:ok, ^path} = Storage.replace(path, replacement)
    assert {:ok, ^replacement} = Storage.read(path)
    assert_staging_clean(directory)
  end

  test "uses a unique same-directory staging file", %{directory: directory} do
    path = Path.join(directory, "manifest.json")
    TestStorageFileOps.capture_open_to(self())
    on_exit(&TestStorageFileOps.clear_capture/0)

    assert {:ok, ^path} =
             Storage.replace(path, %{"revision" => 1}, file_ops: TestStorageFileOps)

    assert_receive {:storage_opened, staging_path}
    assert Path.dirname(staging_path) == directory
    assert String.starts_with?(Path.basename(staging_path), ".manifest.json.")
    assert String.ends_with?(staging_path, ".stage")
  end

  test "retries an exclusive-open race without deleting the foreign stage", %{
    directory: directory
  } do
    path = Path.join(directory, "manifest.json")
    ops = YellowDog.ServerAgent.ForeignStageRaceFileOps
    ops.arm(self())
    on_exit(&ops.clear/0)

    assert {:ok, ^path} = Storage.replace(path, %{"revision" => 1}, file_ops: ops)
    assert_receive {:foreign_stage, foreign_path}
    assert File.read!(foreign_path) == "foreign-stage"
    assert {:ok, %{"revision" => 1}} = Storage.read(path)
  end

  test "treats an exact immutable document as idempotent and changed content as a conflict", %{
    directory: directory
  } do
    path = Path.join(directory, "version.json")
    document = %{"digest" => "abc", "version" => 1}

    assert {:ok, ^path} = Storage.create(path, document)
    assert {:ok, ^path} = Storage.create(path, document)

    assert {:error, %Error{code: :conflict, details: %{}}} =
             Storage.create(path, %{document | "version" => 2})

    assert {:ok, ^document} = Storage.read(path)
    assert_staging_clean(directory)
  end

  test "normalizes atom-keyed JSON objects for immutable idempotency", %{directory: directory} do
    path = Path.join(directory, "version.json")
    document = %{digest: "abc", metadata: %{version: 1}}

    assert {:ok, ^path} = Storage.create(path, document)
    assert {:ok, ^path} = Storage.create(path, document)
    assert {:ok, %{"digest" => "abc", "metadata" => %{"version" => 1}}} = Storage.read(path)
    assert_staging_clean(directory)
  end

  test "rejects structs from the JSON-native document contract", %{directory: directory} do
    path = Path.join(directory, "version.json")
    document = %YellowDog.ServerAgent.JsonEncodableStruct{value: "encoded"}

    assert {:error, %Error{code: :invalid}} = Storage.create(path, document)
    refute File.exists?(path)
  end

  for phase <- [:mkdir_p, :open, :write, :sync, :close, :rename] do
    test "cleans mutable staging and preserves the prior final on #{phase} failure", %{
      directory: directory
    } do
      path = Path.join(directory, "manifest.json")
      previous = %{"revision" => 1}
      replacement = %{"revision" => 2}

      File.write!(path, Jason.encode!(previous))
      TestStorageFileOps.fail_at(unquote(phase))
      on_exit(&TestStorageFileOps.clear_failure/0)

      assert {:error, %Error{code: :internal}} =
               Storage.replace(path, replacement, file_ops: TestStorageFileOps)

      assert {:ok, ^previous} = Storage.read(path)
      assert_staging_clean(directory)
    end
  end

  test "reports a mutable directory sync failure after replacement without a staged file", %{
    directory: directory
  } do
    path = Path.join(directory, "manifest.json")
    replacement = %{"revision" => 2}

    TestStorageFileOps.fail_at(:sync_dir)
    on_exit(&TestStorageFileOps.clear_failure/0)

    assert {:error, %Error{code: :internal}} =
             Storage.replace(path, replacement, file_ops: TestStorageFileOps)

    assert {:ok, ^replacement} = Storage.read(path)
    assert_staging_clean(directory)
  end

  for phase <- [:open, :write, :sync, :close, :link] do
    test "cleans immutable staging and leaves no final on #{phase} failure", %{
      directory: directory
    } do
      path = Path.join(directory, "version.json")
      document = %{"digest" => "abc", "version" => 1}

      TestStorageFileOps.fail_at(unquote(phase))
      on_exit(&TestStorageFileOps.clear_failure/0)

      assert {:error, %Error{code: :internal}} =
               Storage.create(path, document, file_ops: TestStorageFileOps)

      assert {:error, %Error{code: :not_found}} = Storage.read(path)
      assert_staging_clean(directory)
    end
  end

  test "reports an immutable directory sync failure after promotion without a staged file", %{
    directory: directory
  } do
    path = Path.join(directory, "version.json")
    document = %{"digest" => "abc", "version" => 1}

    TestStorageFileOps.fail_at(:sync_dir)
    on_exit(&TestStorageFileOps.clear_failure/0)

    assert {:error, %Error{code: :internal}} =
             Storage.create(path, document, file_ops: TestStorageFileOps)

    assert {:ok, ^document} = Storage.read(path)
    assert_staging_clean(directory)
  end

  test "does not report success when owned-stage cleanup fails after immutable promotion", %{
    directory: directory
  } do
    path = Path.join(directory, "version.json")
    document = %{"version" => 1}
    TestStorageFileOps.return_at(:rm, :malformed)

    assert {:error, %Error{code: :internal}} =
             Storage.create(path, document, file_ops: TestStorageFileOps)

    assert {:ok, ^document} = Storage.read(path)

    assert [_stage] =
             directory
             |> File.ls!()
             |> Enum.filter(&String.ends_with?(&1, ".stage"))
  end

  test "a synchronous rename timeout cannot mutate the final after returning", %{
    directory: directory
  } do
    path = Path.join(directory, "manifest.json")
    replacement = %{"revision" => 2}

    Process.register(self(), :yellow_dog_server_agent_storage_timeout_test)

    assert {:error, %Error{code: :timeout}} =
             Storage.replace(path, replacement,
               file_ops: YellowDog.ServerAgent.TimeoutBeforeRenameFileOps
             )

    assert_receive :rename_started
    Process.sleep(50)
    refute File.exists?(path)
    assert_staging_clean(directory)
  end

  test "returns timeout when directory sync is not confirmed after promotion", %{
    directory: directory
  } do
    path = Path.join(directory, "manifest.json")
    replacement = %{"revision" => 2}

    Process.register(self(), :yellow_dog_server_agent_storage_timeout_test)

    assert {:error, %Error{code: :timeout}} =
             Storage.replace(path, replacement,
               file_ops: YellowDog.ServerAgent.TimeoutDuringSyncDirFileOps
             )

    assert_receive :sync_dir_started
    assert_receive :reconcile_read
    assert {:ok, ^replacement} = Storage.read(path)
    assert_staging_clean(directory)
  end

  test "reconciles an ambiguous rename only after exact normalized read and directory sync", %{
    directory: directory
  } do
    path = Path.join(directory, "manifest.json")
    replacement = %{revision: 2}

    Process.register(self(), :yellow_dog_server_agent_storage_timeout_test)

    assert {:ok, ^path} =
             Storage.replace(path, replacement,
               file_ops: YellowDog.ServerAgent.AmbiguousRenameFileOps
             )

    assert_receive :reconcile_read
    assert {:ok, %{"revision" => 2}} = Storage.read(path)
    assert_staging_clean(directory)
  end

  test "sanitizes malformed read callbacks" do
    TestStorageFileOps.return_at(:read, :malformed)

    assert {:error, %Error{code: :internal}} =
             Storage.read("ignored.json", file_ops: TestStorageFileOps)
  end

  test "returns a typed timeout from a synchronous read callback" do
    TestStorageFileOps.return_at(:read, {:error, :timeout})

    assert {:error, %Error{code: :timeout}} =
             Storage.read("ignored.json", file_ops: TestStorageFileOps)
  end

  for phase <- [:mkdir_p, :exists?, :open] do
    test "returns timeout without cleanup after an unowned #{phase} timeout", %{
      directory: directory
    } do
      path = Path.join(directory, "manifest.json")
      TestStorageFileOps.return_at(unquote(phase), {:error, :timeout})

      assert {:error, %Error{code: :timeout}} =
               Storage.replace(path, %{"revision" => 2}, file_ops: TestStorageFileOps)

      refute File.exists?(path)
      assert_staging_clean(directory)
    end
  end

  for phase <- [:mkdir_p, :exists?, :open, :write, :sync, :close, :rename, :sync_dir] do
    test "sanitizes a malformed #{phase} callback during mutable replacement", %{
      directory: directory
    } do
      path = Path.join(directory, "manifest.json")
      File.write!(path, Jason.encode!(%{"revision" => 1}))
      TestStorageFileOps.return_at(unquote(phase), :malformed)

      assert {:error, %Error{code: :internal}} =
               Storage.replace(path, %{"revision" => 2}, file_ops: TestStorageFileOps)
    end
  end

  test "sanitizes malformed link and rm callbacks", %{directory: directory} do
    path = Path.join(directory, "version.json")
    TestStorageFileOps.return_at(:link, :malformed)

    assert {:error, %Error{code: :internal}} =
             Storage.create(path, %{"version" => 1}, file_ops: TestStorageFileOps)

    TestStorageFileOps.return_at(:rm, :malformed)
    TestStorageFileOps.fail_at(:write)

    assert {:error, %Error{code: :internal}} =
             Storage.create(path, %{"version" => 1}, file_ops: TestStorageFileOps)
  end

  test "rejects the unsupported process-timer option before opening a stage", %{
    directory: directory
  } do
    path = Path.join(directory, "manifest.json")
    TestStorageFileOps.capture_open_to(self())

    assert {:error, %Error{code: :invalid}} =
             Storage.replace(path, %{"revision" => 1},
               file_ops: TestStorageFileOps,
               timeout: 5
             )

    refute_receive {:storage_opened, _path}
  end

  test "default FileOps preserves close failures" do
    assert {:error, {:close, :eio}} =
             FileOps.finalize_close({:ok, "contents"}, {:error, :eio})

    assert {:error, {:close, :eio}} =
             FileOps.finalize_close(:ok, {:error, :eio})

    assert {:error, {:operation_and_close, :enospc, :eio}} =
             FileOps.finalize_close({:error, :enospc}, {:error, :eio})
  end

  defp assert_staging_clean(directory) do
    assert [] =
             directory
             |> File.ls!()
             |> Enum.filter(&String.ends_with?(&1, ".stage"))
  end
end
