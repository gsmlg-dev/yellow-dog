defmodule YellowDog.Management.WorkerAPI do
  @moduledoc "Dedicated machine API scoped by a Worker Bearer credential."
  use Plug.Router
  alias YellowDog.Management.WorkerConnections

  plug(:headers)
  plug(:match)
  plug(:parse_body)
  plug(:dispatch)

  post "/connect" do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] when byte_size(token) == 43 -> token
        _ -> nil
      end

    case WorkerConnections.connect(token, conn.body_params) do
      {:ok, result} -> json(conn, 200, result)
      {:error, %{code: "unauthorized"} = error} -> json(conn, 401, %{error: error})
      {:error, error} -> json(conn, 422, %{error: error})
    end
  end

  match _ do
    json(conn, 404, %{error: %{code: "not_found", message: "Route not found"}})
  end

  defp headers(conn, _) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp parse_body(conn, _) do
    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(parsers: [:json], json_decoder: Jason, length: 65_536)
    )
  rescue
    Plug.Parsers.RequestTooLargeError ->
      conn
      |> json(413, %{error: %{code: "input_limit", message: "Report exceeds 64 KiB"}})
      |> halt()

    Plug.Parsers.ParseError ->
      conn |> json(400, %{error: %{code: "invalid_json", message: "Invalid JSON body"}}) |> halt()

    Plug.Parsers.UnsupportedMediaTypeError ->
      conn
      |> json(415, %{error: %{code: "unsupported_media_type", message: "Use application/json"}})
      |> halt()
  end

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
