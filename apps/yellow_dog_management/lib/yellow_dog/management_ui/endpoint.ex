defmodule YellowDog.ManagementUI.Endpoint do
  use Phoenix.Endpoint, otp_app: :yellow_dog_management

  @session_options [
    store: :cookie,
    key: "_yellow_dog_management",
    signing_salt: "management-session",
    same_site: "Lax",
    http_only: true
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :yellow_dog_management,
    only: ~w(management.css management-live.js favicon.svg)

  plug Plug.RequestId
  plug Plug.Head
  plug Plug.Session, @session_options
  plug YellowDog.ManagementUI.Router
end
