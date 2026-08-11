defmodule YellowDog.Console.MdnsLive.ManagementSupport do
  @moduledoc false

  alias YellowDog.ManagementCore

  def subscribe(socket, server_id) do
    if Phoenix.LiveView.connected?(socket) and
         socket.assigns[:subscribed_server_id] != server_id do
      if old_id = socket.assigns[:subscribed_server_id] do
        Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "management:server:#{old_id}")
      end

      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "management:server:#{server_id}")
    end

    Phoenix.Component.assign(socket, :subscribed_server_id, server_id)
  end

  def refresh_selected_server(socket, server_id) do
    case ManagementCore.get_server(server_id) do
      {:ok, server} ->
        Phoenix.Component.assign(socket,
          selected_server: server,
          service_online?: server.status in [:online, "online"],
          snapshot_observed_at: server.last_seen_at
        )

      _error ->
        socket
    end
  end
end
