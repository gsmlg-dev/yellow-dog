defmodule YellowDog.Store.BackupLocalTest do
  use ExUnit.Case, async: false

  alias YellowDog.Store.Backup

  setup do
    YellowDog.StoreHelper.setup_store()
    :ok
  end

  describe "create/1" do
    @tag :tmp_dir
    test "creates a backup from the active store backend when Concord Ra is unavailable", %{
      tmp_dir: tmp_dir
    } do
      previous_backup_dir = Application.get_env(:yellow_dog, :backup_dir)
      Application.put_env(:yellow_dog, :backup_dir, tmp_dir)

      on_exit(fn ->
        if is_nil(previous_backup_dir) do
          Application.delete_env(:yellow_dog, :backup_dir)
        else
          Application.put_env(:yellow_dog, :backup_dir, previous_backup_dir)
        end
      end)

      :ok = YellowDog.Store.backend_put("config:dns:example", %{enabled: true})

      assert {:ok, path} = Backup.create(dir: tmp_dir, label: "local")
      assert File.exists?(path)
      assert {:ok, %{valid: true}} = Backup.verify(path)

      {:ok, backups} = Backup.list(dir: tmp_dir)
      assert [%{path: ^path, entry_count: 1}] = backups
    end
  end

  describe "restore/2" do
    @tag :tmp_dir
    test "restores a local backend backup into the active store backend", %{tmp_dir: tmp_dir} do
      previous_backup_dir = Application.get_env(:yellow_dog, :backup_dir)
      Application.put_env(:yellow_dog, :backup_dir, tmp_dir)

      on_exit(fn ->
        if is_nil(previous_backup_dir) do
          Application.delete_env(:yellow_dog, :backup_dir)
        else
          Application.put_env(:yellow_dog, :backup_dir, previous_backup_dir)
        end
      end)

      value = %{enabled: true}
      :ok = YellowDog.Store.backend_put("config:dns:example", value)
      assert {:ok, path} = Backup.create(dir: tmp_dir, label: "local")

      :ok = YellowDog.Store.backend_delete("config:dns:example")
      assert {:error, :not_found} = YellowDog.Store.backend_get("config:dns:example")

      assert {:ok, %{restored: true, keys_restored: 1}} = Backup.restore(path, confirm: true)
      assert {:ok, ^value} = YellowDog.Store.backend_get("config:dns:example")
    end
  end
end
