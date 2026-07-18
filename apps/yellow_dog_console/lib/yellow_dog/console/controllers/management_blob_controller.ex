defmodule YellowDog.Console.ManagementBlobController do
  @moduledoc """
  Serves verified management blobs to authenticated service runtimes.
  """

  use YellowDog.Console, :controller

  alias YellowDog.ManagementCore

  @default_max_blob_bytes 500 * 1024 * 1024

  def show(conn, %{"sha256" => digest}) do
    case ManagementCore.open_blob(digest, max_blob_bytes()) do
      {:ok, handle} ->
        stream_blob(conn, handle)

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

  defp stream_blob(conn, handle) do
    digest = ManagementCore.blob_digest(handle)

    try do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("content-type", "application/octet-stream")
      |> put_resp_header("etag", ~s("#{digest}"))
      |> send_chunked(200)
      |> stream_chunks(handle)
    after
      ManagementCore.close_blob(handle)
    end
  end

  defp stream_chunks(conn, handle) do
    case ManagementCore.read_blob(handle) do
      {:ok, content} ->
        case chunk(conn, content) do
          {:ok, conn} -> stream_chunks(conn, handle)
          {:error, _reason} -> halt(conn)
        end

      :eof ->
        conn

      {:error, _reason} ->
        halt(conn)
    end
  end

  defp send_error(conn, status, message),
    do: conn |> put_status(status) |> text(message)
end
