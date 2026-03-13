defmodule YellowDog.Console.NetmanLive.DhcpClientLive do
  @moduledoc """
  DHCP Client page for a connected Netman service instance.
  Shows active DHCP connections and lease information.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.NetmanRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: NetmanRegistry.subscribe()
    {:ok, assign(socket, page_title: "DHCP Client")}
  end

  @impl true
  def handle_params(%{"node_id" => node_id}, _uri, socket) do
    case NetmanRegistry.get(node_id) do
      {:ok, client} ->
        {:noreply,
         assign(socket,
           node_id: node_id,
           client: client,
           page_title: "#{client.hostname} — DHCP Client"
         )}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "Netman node \"#{node_id}\" is not connected")
         |> push_navigate(to: "/netman")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center gap-2">
          <.link navigate={"/netman/#{@node_id}"} class="btn btn-ghost btn-sm btn-circle">
            <.dm_mdi name="arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-4xl font-bold">DHCP Client</h1>
            <p class="mt-1 text-on-surface-variant">
              {@client.hostname} · <span class="font-mono text-sm">{@client.ip}</span>
            </p>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4">
          <.card>
            <div class="text-sm text-on-surface-variant">Active Connections</div>
            <div class="text-2xl font-bold text-success">{length(@client.connections)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Default Route</div>
            <div class="text-lg font-bold font-mono">{@client.default_route || "-"}</div>
          </.card>
        </div>

        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Connections</h2>
            <%= if @client.connections == [] do %>
              <div class="text-center py-8 text-on-surface-variant">
                <.dm_mdi name="lan-disconnect" class="h-12 w-12 mx-auto mb-3" />
                <p>No active DHCP connections</p>
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-striped">
                  <thead>
                    <tr>
                      <th>Interface</th>
                      <th>Profile</th>
                      <th>State</th>
                      <th>IP Address</th>
                      <th>Gateway</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for conn <- @client.connections do %>
                      <tr>
                        <td class="font-mono font-semibold">{conn_field(conn, "interface")}</td>
                        <td>{conn_field(conn, "profile_id")}</td>
                        <td>
                          <.badge color={conn_state_color(conn)} size="sm">
                            {conn_field(conn, "state")}
                          </.badge>
                        </td>
                        <td class="font-mono text-sm">{conn_field(conn, "ip")}</td>
                        <td class="font-mono text-sm">{conn_field(conn, "gateway")}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({event, %{node_id: node_id}}, socket)
      when event in [:netman_joined, :netman_updated] and node_id == socket.assigns.node_id do
    case NetmanRegistry.get(node_id) do
      {:ok, client} -> {:noreply, assign(socket, :client, client)}
      :error -> {:noreply, push_navigate(socket, to: "/netman")}
    end
  end

  def handle_info({:netman_left, %{node_id: node_id}}, socket)
      when node_id == socket.assigns.node_id do
    {:noreply,
     socket
     |> put_flash(:info, "Node disconnected")
     |> push_navigate(to: "/netman")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp conn_field(conn, key) when is_map(conn), do: conn[key] || "-"
  defp conn_field(_, _), do: "-"

  defp conn_state_color(conn) when is_map(conn) do
    case conn["state"] do
      "activated" -> "success"
      "configuring" -> "warning"
      "ip_check" -> "info"
      "prepare" -> "warning"
      "disconnected" -> "ghost"
      _ -> "ghost"
    end
  end

  defp conn_state_color(_), do: "ghost"
end
