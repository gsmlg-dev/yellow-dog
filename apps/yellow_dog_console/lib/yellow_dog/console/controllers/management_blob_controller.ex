defmodule YellowDog.Console.ManagementBlobController do
  @moduledoc """
  Serves verified management blobs to authenticated service runtimes.
  """

  use YellowDog.Console, :controller

  alias YellowDog.ManagementCore

  @default_max_blob_bytes 500 * 1024 * 1024

  def show(conn, %{"sha256" => digest}) do
    case ManagementCore.get_blob(digest, max_blob_bytes()) do
      {:ok, %{digest: ^digest, path: path, size: size}}
      when is_binary(path) and is_integer(size) and size >= 0 ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("content-length", Integer.to_string(size))
        |> put_resp_header("content-type", "application/octet-stream")
        |> put_resp_header("etag", ~s("#{digest}"))
        |> send_file(200, path)

      {:error, %{code: :invalid, details: %{"reason" => "too_large"}}} ->
        send_error(conn, 413, "Payload Too Large")

      {:error, %{code: :invalid, details: %{"reason" => "digest_mismatch"}}} ->
        send_error(conn, 422, "Unprocessable Content")

      {:error, %{code: :invalid}} ->
        send_error(conn, 400, "Bad Request")

      {:error, %{code: :not_found}} ->
        send_error(conn, 404, "Not Found")

      _error ->
        send_error(conn, 500, "Internal Server Error")
    end
  end

  defp max_blob_bytes do
    case Application.get_env(
           :yellow_dog_console,
           :management_blob_max_bytes,
           @default_max_blob_bytes
         ) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @default_max_blob_bytes
    end
  end

  defp send_error(conn, status, message),
    do: conn |> put_status(status) |> text(message)
end
