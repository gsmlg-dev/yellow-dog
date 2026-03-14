defmodule YellowDog.Console.NetmanChannel do
  @moduledoc """
  Channel for communication with remote Netman service instances.

  Remote Netman clients join `"netman:control"` and push status updates.
  The channel tracks connected clients via `NetmanRegistry` and broadcasts
  presence changes to the console LiveView via PubSub.
  """

  use YellowDog.Console, :channel

  require Logger

  alias YellowDog.Console.NetmanRegistry

  @impl true
  def join("netman:control", payload, socket) do
    socket =
      socket
      |> assign(:ip, payload["ip"] || "unknown")
      |> assign(:interfaces, payload["interfaces"] || [])
      |> assign(:connections, payload["connections"] || [])
      |> assign(:default_route, payload["default_route"])
      |> assign(:resolved, payload["resolved"])
      |> assign(:joined_at, DateTime.utc_now())

    info = client_info(socket)
    NetmanRegistry.register(info)
    Logger.info("[NetmanChannel] Client joined: #{socket.assigns.node_id}")

    {:ok, %{status: "connected"}, socket}
  end

  @impl true
  def handle_in("status", payload, socket) do
    socket =
      socket
      |> assign(:interfaces, payload["interfaces"] || socket.assigns.interfaces)
      |> assign(:connections, payload["connections"] || socket.assigns.connections)
      |> assign(:default_route, payload["default_route"] || socket.assigns.default_route)
      |> assign(:resolved, payload["resolved"] || socket.assigns.resolved)

    NetmanRegistry.update(client_info(socket))
    {:noreply, socket}
  end

  def handle_in("query_log", payload, socket) do
    Phoenix.PubSub.broadcast(
      YellowDog.Console.PubSub,
      "netman:query_log:#{socket.assigns.node_id}",
      {:query_log_entry, payload}
    )

    {:noreply, socket}
  end

  def handle_in("heartbeat", _payload, socket) do
    NetmanRegistry.touch(socket.assigns.node_id)
    {:reply, :ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    NetmanRegistry.unregister(socket.assigns.node_id)
    :ok
  end

  defp client_info(socket) do
    %{
      node_id: socket.assigns.node_id,
      hostname: socket.assigns.hostname,
      version: socket.assigns.version,
      ip: socket.assigns.ip,
      interfaces: socket.assigns.interfaces,
      connections: socket.assigns.connections,
      default_route: socket.assigns.default_route,
      resolved: socket.assigns.resolved,
      joined_at: socket.assigns.joined_at,
      last_seen: DateTime.utc_now()
    }
  end
end
