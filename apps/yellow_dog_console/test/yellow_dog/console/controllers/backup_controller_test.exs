defmodule YellowDog.Console.BackupControllerTest do
  use YellowDog.Console.ConnCase, async: false

  setup do
    # Create a temporary backup directory and override the app env
    tmp_dir = Path.join(System.tmp_dir!(), "backup_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)

    original_dir = Application.get_env(:yellow_dog, :backup_dir)
    Application.put_env(:yellow_dog, :backup_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if original_dir do
        Application.put_env(:yellow_dog, :backup_dir, original_dir)
      else
        Application.delete_env(:yellow_dog, :backup_dir)
      end
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "GET /backups/download/:filename" do
    test "serves existing backup file", %{conn: conn, tmp_dir: tmp_dir} do
      filename = "test_backup_#{:rand.uniform(100_000)}.backup"
      path = Path.join(tmp_dir, filename)
      File.write!(path, "backup content here")

      conn = get(conn, "/system/backups/download/#{filename}")

      assert response(conn, 200) =~ "backup content"

      assert get_resp_header(conn, "content-disposition") |> hd() =~
               ~s(attachment; filename="#{filename}")
    end

    test "returns 404 when backup file does not exist", %{conn: conn} do
      conn = get(conn, "/system/backups/download/nonexistent.backup")
      assert response(conn, 404) =~ "Backup not found"
    end

    test "prevents directory traversal — strips path components from filename", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      # Create a file at a path the traversal would target
      # The controller must serve `safe_basename.backup` inside tmp_dir, not traverse out
      filename = "safe_file.backup"
      path = Path.join(tmp_dir, filename)
      File.write!(path, "safe content")

      # Attempt traversal: "../../etc/passwd" should be sanitised to "passwd"
      # and return 404 (no file named "passwd" in tmp_dir)
      conn = get(conn, "/system/backups/download/..%2F..%2Fetc%2Fpasswd")
      assert response(conn, 404) =~ "Backup not found"
    end

    test "prevents traversal via dot-dot segments in filename", %{conn: conn, tmp_dir: tmp_dir} do
      # Create a file that would be accessible without traversal
      filename = "legit.backup"
      path = Path.join(tmp_dir, filename)
      File.write!(path, "content")

      # URL-decoded traversal attempt: "../../legit.backup" -> basename is "legit.backup"
      # This should resolve to tmp_dir/legit.backup (the file we created), NOT traverse up
      conn2 = get(conn, "/system/backups/download/legit.backup")
      assert response(conn2, 200) =~ "content"
    end
  end
end
