defmodule YellowDog.Management.ResourceMetadata do
  @moduledoc false
  import Plug.Conn
  alias YellowDog.Management.{Auth, IntegrationSettings}
  def init(opts), do: opts

  def call(conn, _) do
    config = IntegrationSettings.get()

    with :ok <- Auth.guard_request(conn, config),
         true <- config.mode == :protected_remote and (config.http_enabled or config.mcp_enabled),
         true <-
           conn.method == "GET" and
             conn.path_info in [["oauth-protected-resource"], ["oauth-protected-resource", "mcp"]] do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Jason.encode!(Auth.metadata()))
    else
      {:error, _} -> send_resp(conn, 403, "Management Host or Origin rejected")
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
