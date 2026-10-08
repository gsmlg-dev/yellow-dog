defmodule YellowDog.ManagementUI.TrustedProxy do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    trusted_ip = conn.private.phoenix_endpoint.config(:trusted_proxy_ip)

    if trusted_ip && Plug.Conn.get_peer_data(conn).address == trusted_ip do
      Plug.RewriteOn.call(conn, [:x_forwarded_proto, :x_forwarded_port])
    else
      conn
    end
  end
end
