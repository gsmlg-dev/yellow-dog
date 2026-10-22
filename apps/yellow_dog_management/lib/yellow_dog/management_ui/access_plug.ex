defmodule YellowDog.ManagementUI.AccessPlug do
  @moduledoc false
  import Plug.Conn
  alias YellowDog.Management.{Access, Auth, Caller}
  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, caller} <- Auth.authenticate(conn, :ui),
         :ok <- Access.authorize(caller, "config:read"),
         :ok <-
           Access.authorize(
             caller,
             YellowDog.ManagementUI.Hooks.Authorization.path_scope(conn.request_path)
           ) do
      conn
      |> assign(:caller, caller)
      |> put_session("management_caller", Caller.session(caller))
      |> put_resp_header("cache-control", "no-store")
    else
      {:error, error} ->
        status =
          case error.code do
            "adapters_disabled" -> 503
            "forbidden" -> 403
            _ -> 401
          end

        conn
        |> Auth.challenge(error)
        |> put_resp_content_type("text/plain")
        |> send_resp(status, error.message)
        |> halt()
    end
  end
end
