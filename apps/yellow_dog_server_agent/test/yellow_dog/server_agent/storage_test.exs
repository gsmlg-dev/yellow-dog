defmodule YellowDog.ServerAgent.StorageTest do
  use ExUnit.Case, async: false

  alias YellowDog.ServerAgent.Storage
  alias YellowDog.ServerAgent.TestStorageFileOps
  alias YellowDog.Sync.Error

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-server-agent-storage-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)

    on_exit(fn -> File.rm_rf(directory) end)

    %{directory: directory}
  end

  test "creates and reads an immutable JSON object", %{directory: directory} do
    path = Path.join(directory, "journal.json")
    document = %{"request_id" => "request-1", "status" => "received"}

    assert {:ok, ^path} = Storage.create(path, document)
    assert {:ok, ^document} = Storage.read(path)
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

  test "reconciles a timeout after rename by reading the exact final once", %{
    directory: directory
  } do
    path = Path.join(directory, "manifest.json")
    replacement = %{"revision" => 2}

    Process.register(self(), :yellow_dog_server_agent_storage_timeout_test)

    assert {:ok, ^path} =
             Storage.replace(path, replacement,
               file_ops: YellowDog.ServerAgent.TimeoutAfterRenameFileOps,
               timeout: 5
             )

    assert_receive :rename_called
    refute_receive :rename_called, 100
    assert {:ok, ^replacement} = Storage.read(path)
    assert_staging_clean(directory)
  end

  defp assert_staging_clean(directory) do
    assert [] =
             directory
             |> File.ls!()
             |> Enum.filter(&String.ends_with?(&1, ".stage"))
  end
end
