defmodule YellowDog.Console.BackupController do
  @moduledoc """
  Serves backup files for download.

  The backup directory is sourced from `YellowDog.Store.Backup.default_dir/0`
  so the controller and the backup module always agree on the location.
  """

  use YellowDog.Console, :controller

  def download(conn, %{"filename" => filename}) do
    backup_dir = YellowDog.Store.Backup.default_dir()
    # Prevent directory traversal — Path.basename strips any leading path components
    safe_name = Path.basename(filename)
    path = Path.join(backup_dir, safe_name)

    if File.exists?(path) do
      # send_file/5 uses zero-copy sendfile(2) syscall when supported,
      # avoiding loading the entire backup into memory
      conn
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{safe_name}"))
      |> send_file(200, path)
    else
      conn
      |> put_status(:not_found)
      |> text("Backup not found")
    end
  end
end
