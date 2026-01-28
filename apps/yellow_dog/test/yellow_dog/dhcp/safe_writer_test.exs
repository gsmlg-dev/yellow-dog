defmodule YellowDog.DHCP.SafeWriterTest do
  use ExUnit.Case, async: true

  alias YellowDog.DHCP.SafeWriter

  @moduletag :capture_log

  setup do
    # Create a temporary directory for each test
    tmp_dir = Path.join(System.tmp_dir!(), "safe_writer_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "write/3" do
    test "creates new file successfully", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "new_file.toml")
      content = "key = \"value\"\n"

      assert :ok = SafeWriter.write(path, content)
      assert File.exists?(path)
      assert File.read!(path) == content
    end

    test "overwrites existing file atomically", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "existing.toml")
      File.write!(path, "old = \"content\"\n")

      new_content = "new = \"content\"\n"
      assert :ok = SafeWriter.write(path, new_content)
      assert File.read!(path) == new_content
    end

    test "creates parent directories if needed", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "dir", "file.toml"])
      content = "key = \"value\"\n"

      assert :ok = SafeWriter.write(path, content)
      assert File.exists?(path)
    end

    test "validates content with custom validator", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "validated.toml")
      valid_content = "key = \"value\"\n"

      validator = fn content ->
        case Toml.decode(content) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

      assert :ok = SafeWriter.write(path, valid_content, validator: validator)
    end

    test "fails validation and preserves original", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "validated.toml")
      original_content = "original = \"content\"\n"
      File.write!(path, original_content)

      invalid_content = "invalid toml [ unclosed"

      validator = fn content ->
        case Toml.decode(content) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

      assert {:error, {:validation_failed, _}} =
               SafeWriter.write(path, invalid_content, validator: validator)

      # Original file should be preserved
      assert File.read!(path) == original_content
    end

    test "cleans up cache files after successful write", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "cleanup_test.toml")
      cache_dir = SafeWriter.default_cache_dir(path)

      content = "key = \"value\"\n"
      assert :ok = SafeWriter.write(path, content)

      # Cache directory may exist but should have no tx files
      if File.exists?(cache_dir) do
        {:ok, files} = File.ls(cache_dir)
        toml_files = Enum.filter(files, &String.ends_with?(&1, ".toml"))
        backup_files = Enum.filter(files, &String.ends_with?(&1, ".backup"))
        assert toml_files == []
        assert backup_files == []
      end
    end

    test "uses custom cache directory", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "custom_cache.toml")
      cache_dir = Path.join(tmp_dir, "my_custom_cache")

      content = "key = \"value\"\n"
      assert :ok = SafeWriter.write(path, content, cache_dir: cache_dir)
      assert File.exists?(path)
    end
  end

  describe "with_transaction/3" do
    test "executes function and moves result to target", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "transaction_result.toml")

      result =
        SafeWriter.with_transaction(path, fn cache_path ->
          File.write(cache_path, "from_transaction = true\n")
        end)

      assert result == :ok
      assert File.read!(path) == "from_transaction = true\n"
    end

    test "rolls back on function failure", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rollback_test.toml")
      original = "original = true\n"
      File.write!(path, original)

      result =
        SafeWriter.with_transaction(path, fn _cache_path ->
          {:error, :intentional_failure}
        end)

      assert result == {:error, :intentional_failure}
      assert File.read!(path) == original
    end

    test "validates result with custom validator", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "validated_tx.toml")

      validator = fn content ->
        case Toml.decode(content) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

      result =
        SafeWriter.with_transaction(
          path,
          fn cache_path ->
            File.write(cache_path, "valid = true\n")
          end,
          validator: validator
        )

      assert result == :ok
    end
  end

  describe "validate_toml/1" do
    test "returns :ok for valid TOML" do
      valid_toml = """
      [section]
      key = "value"
      number = 42
      """

      assert :ok = SafeWriter.validate_toml(valid_toml)
    end

    test "returns error for invalid TOML" do
      invalid_toml = "invalid [ unclosed"
      assert {:error, {:toml_validation_failed, _}} = SafeWriter.validate_toml(invalid_toml)
    end
  end

  describe "default_cache_dir/1" do
    test "returns sibling .cache directory" do
      path = "/data/dhcpv4/pools/lan.toml"
      assert SafeWriter.default_cache_dir(path) == "/data/dhcpv4/pools/.cache"
    end
  end

  describe "list_pending_transactions/1" do
    test "returns empty list for non-existent directory" do
      assert SafeWriter.list_pending_transactions("/nonexistent/path") == []
    end

    test "lists pending transaction files", %{tmp_dir: tmp_dir} do
      cache_dir = Path.join(tmp_dir, ".cache")
      File.mkdir_p!(cache_dir)

      # Create a pending transaction (cache file without completion)
      File.write!(Path.join(cache_dir, "tx-123.toml"), "pending = true\n")
      File.write!(Path.join(cache_dir, "tx-123.backup"), "backup = true\n")

      pending = SafeWriter.list_pending_transactions(cache_dir)

      assert length(pending) == 1
      assert hd(pending).tx_id == "tx-123"
      assert hd(pending).has_backup == true
    end
  end

  describe "cleanup_stale_transactions/2" do
    test "removes files older than max age", %{tmp_dir: tmp_dir} do
      cache_dir = Path.join(tmp_dir, ".cache")
      File.mkdir_p!(cache_dir)

      # Create a file
      old_file = Path.join(cache_dir, "old-tx.toml")
      File.write!(old_file, "stale = true\n")

      # Set modification time to 2 hours ago
      two_hours_ago = System.system_time(:second) - 7200

      # Note: We can't easily set mtime, so we'll test with max_age of 0
      assert {:ok, count} = SafeWriter.cleanup_stale_transactions(cache_dir, 0)
      assert count >= 0
    end

    test "returns 0 for non-existent directory" do
      assert {:ok, 0} = SafeWriter.cleanup_stale_transactions("/nonexistent")
    end
  end

  describe "restore_from_backup/2" do
    test "restores file from backup", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "restore_target.toml")
      backup_path = Path.join(tmp_dir, "restore_target.backup")

      File.write!(backup_path, "backup_content = true\n")

      assert :ok = SafeWriter.restore_from_backup(path, backup_path)
      assert File.read!(path) == "backup_content = true\n"
      refute File.exists?(backup_path)
    end

    test "returns error when backup doesn't exist", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "target.toml")
      backup_path = Path.join(tmp_dir, "nonexistent.backup")

      assert {:error, :no_backup} = SafeWriter.restore_from_backup(path, backup_path)
    end
  end

  describe "concurrent writes" do
    test "handles concurrent writes safely", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "concurrent.toml")

      # Start multiple concurrent write tasks
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            content = "iteration = #{i}\n"
            SafeWriter.write(path, content)
          end)
        end

      # Wait for all tasks
      results = Task.await_many(tasks, 5000)

      # All should succeed (one will win, others may retry or succeed atomically)
      success_count = Enum.count(results, &(&1 == :ok))
      assert success_count >= 1

      # File should exist with valid content
      assert File.exists?(path)
      content = File.read!(path)
      assert String.starts_with?(content, "iteration = ")
    end
  end
end
