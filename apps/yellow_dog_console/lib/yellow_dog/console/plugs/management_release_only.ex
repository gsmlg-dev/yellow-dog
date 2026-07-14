defmodule YellowDog.Console.Plugs.ManagementReleaseOnly do
  @moduledoc """
  Restricts the slim management-core release to the Management console surface.
  """

  import Plug.Conn

  @behaviour Plug

  @management_release "yellow_dog_management_core"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if management_release_only?() do
      route_management_request(conn)
    else
      conn
    end
  end

  defp route_management_request(%{request_path: "/"} = conn) do
    conn
    |> put_resp_header("location", "/management")
    |> send_resp(302, "")
    |> halt()
  end

  defp route_management_request(conn) do
    if allowed_path?(conn.request_path) do
      conn
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end

  defp allowed_path?("/management"), do: true
  defp allowed_path?("/management/" <> _rest), do: true
  defp allowed_path?("/live" <> _rest), do: true
  defp allowed_path?("/assets/" <> _rest), do: true
  defp allowed_path?("/favicon" <> _rest), do: true
  defp allowed_path?(_path), do: false

  def management_release_only? do
    Application.get_env(:yellow_dog_console, :management_release_only, false) == true or
      System.get_env("RELEASE_NAME") == @management_release
  end
end
