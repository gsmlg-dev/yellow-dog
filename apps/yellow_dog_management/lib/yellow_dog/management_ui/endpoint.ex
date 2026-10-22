defmodule YellowDog.ManagementUI.Endpoint do
  use Phoenix.Endpoint, otp_app: :yellow_dog_management

  @session_options [
    store: :cookie,
    key: "_yellow_dog_management",
    signing_salt: "management-session",
    same_site: "Lax",
    http_only: true
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:x_headers, :peer_data, :uri, session: @session_options]]

  plug YellowDog.ManagementUI.TrustedProxy

  plug Plug.Static,
    at: "/",
    from: :yellow_dog_management,
    only: ~w(management.css management-live.js favicon.svg)

  plug Plug.RequestId
  plug Plug.Head
  plug :management_session
  plug YellowDog.ManagementUI.Router

  defp management_session(conn, _) do
    secure = YellowDog.Management.IntegrationSettings.get().mode == :protected_remote
    Plug.Session.call(conn, Plug.Session.init(Keyword.put(@session_options, :secure, secure)))
  end
end
