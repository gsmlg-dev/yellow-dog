defmodule YellowDog.Store.BackupTest do
  use ExUnit.Case, async: false

  @moduletag :store_integration
  @moduletag :skip

  alias YellowDog.Store.Backup

  describe "create/1" do
    test "creates a backup file" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "yellow_dog_backup_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, path} = Backup.create(dir: dir, label: "test-backup")
      assert File.exists?(path)
    end

    test "create with default options" do
      assert {:ok, path} = Backup.create()
      assert is_binary(path)

      on_exit(fn -> File.rm(path) end)
    end
  end

  describe "restore/2" do
    test "restore without confirm returns error" do
      assert {:error, :confirm_required} = Backup.restore("/tmp/nonexistent.backup")
    end

    test "restore with verify_only delegates to verify" do
      # This will fail because the file doesn't exist, but it should
      # call verify rather than the actual restore path
      result = Backup.restore("/tmp/nonexistent.backup", verify_only: true)
      assert {:error, _reason} = result
    end

    test "restore with confirm proceeds" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "yellow_dog_restore_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, path} = Backup.create(dir: dir)
      assert {:ok, stats} = Backup.restore(path, confirm: true)
      assert stats.restored == true
    end
  end

  describe "verify/1" do
    test "verifies a valid backup" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "yellow_dog_verify_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, path} = Backup.create(dir: dir)
      assert {:ok, stats} = Backup.verify(path)
      assert stats.valid == true
      assert stats.path == path
    end
  end

  describe "list/1" do
    test "lists backups in directory" do
      dir =
        Path.join(System.tmp_dir!(), "yellow_dog_list_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      Backup.create(dir: dir)
      assert {:ok, backups} = Backup.list(dir: dir)
      assert is_list(backups)
    end
  end

  describe "delete/1" do
    test "deletes a backup file" do
      path =
        Path.join(
          System.tmp_dir!(),
          "yellow_dog_delete_test_#{System.unique_integer([:positive])}.backup"
        )

      File.write!(path, "test")

      on_exit(fn -> File.rm(path) end)

      assert :ok = Backup.delete(path)
      refute File.exists?(path)
    end

    test "delete nonexistent file returns error" do
      assert {:error, :enoent} =
               Backup.delete("/tmp/nonexistent_#{System.unique_integer([:positive])}.backup")
    end
  end
end
