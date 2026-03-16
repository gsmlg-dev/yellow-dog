defmodule YellowDog.Console.BackupController do
  @moduledoc """
  Serves backup files for download.
  """

  use YellowDog.Console, :controller

  def download(conn, %{"filename" => filename}) do
    backup_dir = "./backups"
    # Prevent directory traversal
    safe_name = Path.basename(filename)
    path = Path.join(backup_dir, safe_name)

    if File.exists?(path) do
      send_download(conn, {:file, path}, filename: safe_name)
    else
      conn
      |> put_status(:not_found)
      |> text("Backup not found")
    end
  end
end
