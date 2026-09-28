defmodule YellowDog.Console.Plugs.DnsRequestBodyLimit do
  @moduledoc "Bounds DNS mutation bodies before JSON decoding."

  import Plug.Conn, except: [read_body: 2]

  @max_bytes 65_536

  def init(opts), do: opts

  def call(%{method: method, request_path: "/api/v1/zones" <> _} = conn, _opts)
      when method in ["POST", "PATCH"] do
    case Plug.Conn.read_body(conn, length: @max_bytes, read_length: @max_bytes + 1) do
      {:ok, body, conn} ->
        put_private(conn, :dns_request_body, body)

      {:more, _body, conn} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          413,
          Jason.encode!(%{error: %{code: "too_large", message: "request exceeds 65536 bytes"}})
        )
        |> halt()

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            error: %{code: "invalid_body", message: "request body could not be read"}
          })
        )
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  def read_body(conn, opts) do
    case conn.private do
      %{dns_request_body: body} -> {:ok, body, conn}
      _ -> Plug.Conn.read_body(conn, opts)
    end
  end
end
