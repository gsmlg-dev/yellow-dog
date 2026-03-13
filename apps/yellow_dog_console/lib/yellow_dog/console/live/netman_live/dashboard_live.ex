defmodule YellowDog.Console.NetmanLive.DashboardLive do
  @moduledoc """
  Netman dashboard — shows remote Netman service instances connected
  via WebSocket and provides documentation on how to connect.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.NetmanRegistry

  @join_example ~S"""
  channel.join("netman:control", %{
    "ip" => "192.168.1.100",
    "interfaces" => [...],
    "connections" => [...],
    "default_route" => "eth0"
  })
  """

  @push_example ~S"""
  channel.push("status", %{
    "interfaces" => [...],
    "connections" => [...],
    "default_route" => "eth0"
  })

  channel.push("heartbeat", %{})
  """

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: NetmanRegistry.subscribe()

    {:ok,
     assign(socket,
       page_title: "Network Manager",
       clients: NetmanRegistry.list(),
       show_docs: false,
       ws_host: ws_host(),
       join_example: @join_example,
       push_example: @push_example
     )}
  end

  defp ws_host do
    endpoint_config = Application.get_env(:yellow_dog_console, YellowDog.Console.Endpoint, [])
    url = Keyword.get(endpoint_config, :url, [])
    host = Keyword.get(url, :host, "localhost")
    port = Keyword.get(endpoint_config |> Keyword.get(:http, []), :port, 4270)
    "#{host}:#{port}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <!-- Header -->
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-4xl font-bold">Network Manager</h1>
            <p class="mt-2 text-on-surface-variant">
              Manage remote Netman service instances connected via WebSocket
            </p>
          </div>
          <div class="flex items-center gap-3">
            <.badge color="info" size="lg">
              {length(@clients)} connected
            </.badge>
            <button
              phx-click="toggle_docs"
              class={"btn btn-sm " <> if(@show_docs, do: "btn-primary", else: "btn-ghost")}
            >
              <.dm_mdi name="book-open-variant" class="h-4 w-4" />
              <span>Connect Guide</span>
            </button>
          </div>
        </div>
        
    <!-- Connection Documentation -->
        <%= if @show_docs do %>
          <div class="card bg-surface shadow-xl">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <h2 class="card-title">How to Connect a Netman Service</h2>
                <button phx-click="toggle_docs" class="btn btn-ghost btn-sm btn-circle">
                  <.dm_mdi name="close" class="h-5 w-5" />
                </button>
              </div>

              <div class="space-y-4 mt-2">
                <p class="text-on-surface-variant">
                  Remote Netman instances connect to this console via WebSocket.
                  Use any Phoenix Channel client to establish the connection.
                </p>

                <div class="divider">1. WebSocket Endpoint</div>
                <div class="bg-surface-container rounded-lg p-4">
                  <code class="text-sm font-mono text-primary">
                    ws://{@ws_host}/netman/ws/websocket
                  </code>
                </div>

                <div class="divider">2. Connection Parameters</div>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Parameter</th>
                        <th>Required</th>
                        <th>Description</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr>
                        <td class="font-mono text-sm">token</td>
                        <td>
                          <.badge color="error" size="sm">Required</.badge>
                        </td>
                        <td>Authentication token</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">node_id</td>
                        <td>
                          <.badge color="error" size="sm">Required</.badge>
                        </td>
                        <td>Unique identifier for this Netman instance</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">hostname</td>
                        <td>
                          <.badge color="ghost" size="sm">Optional</.badge>
                        </td>
                        <td>Human-readable hostname (defaults to node_id)</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">version</td>
                        <td>
                          <.badge color="ghost" size="sm">Optional</.badge>
                        </td>
                        <td>Netman software version</td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <div class="divider">3. Join Channel</div>
                <p class="text-on-surface-variant text-sm">
                  After connecting, join the <code class="text-primary">netman:control</code> channel
                  with initial status payload:
                </p>
                <div class="bg-surface-container rounded-lg p-4">
                  <pre class="text-sm font-mono text-on-surface"><code>{@join_example}</code></pre>
                </div>

                <div class="divider">4. Push Status Updates</div>
                <p class="text-on-surface-variant text-sm">
                  Periodically push status updates to keep the dashboard current:
                </p>
                <div class="bg-surface-container rounded-lg p-4">
                  <pre class="text-sm font-mono text-on-surface"><code>{@push_example}</code></pre>
                </div>

                <div class="divider">Elixir Client Example</div>
                <div class="bg-surface-container rounded-lg p-4">
                  <pre class="text-sm font-mono text-on-surface"><code>{"# In your Netman application\n{:ok, socket} = Phoenix.Channels.GenSocketClient.start_link(\n  Phoenix.Channels.GenSocketClient.Transport.WebSocketClient,\n  __MODULE__,\n  \"ws://#{@ws_host}/netman/ws/websocket?\" <>\n    URI.encode_query(token: \"your-token\", node_id: \"node-1\", hostname: \"router-1\")\n)"}</code></pre>
                </div>
              </div>
            </div>
          </div>
        <% end %>
        
    <!-- Summary Stats -->
        <div class="grid grid-cols-2 sm:grid-cols-3 gap-4">
          <.card>
            <div class="text-sm text-on-surface-variant">Connected Clients</div>
            <div class="text-2xl font-bold text-primary">{length(@clients)}</div>
            <div class="text-xs text-on-surface-variant">Via WebSocket</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Total Interfaces</div>
            <div class="text-2xl font-bold text-info">{total_interfaces(@clients)}</div>
            <div class="text-xs text-on-surface-variant">Across all clients</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Total Connections</div>
            <div class="text-2xl font-bold text-success">{total_connections(@clients)}</div>
            <div class="text-xs text-on-surface-variant">Active network connections</div>
          </.card>
        </div>
        
    <!-- Connected Clients -->
        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Connected Netman Instances</h2>

            <%= if @clients == [] do %>
              <div class="text-center py-12 text-on-surface-variant">
                <.dm_mdi name="lan-disconnect" class="h-16 w-16 mx-auto mb-4" />
                <p class="text-lg">No Netman instances connected</p>
                <p class="text-sm mt-2">
                  Click <strong>Connect Guide</strong> above to learn how to connect a Netman service
                </p>
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-striped">
                  <thead>
                    <tr>
                      <th>Node ID</th>
                      <th>Hostname</th>
                      <th>IP Address</th>
                      <th>Version</th>
                      <th>Interfaces</th>
                      <th>Connections</th>
                      <th>Default Route</th>
                      <th>Connected Since</th>
                      <th>Last Seen</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for client <- @clients do %>
                      <tr
                        class="cursor-pointer hover:bg-surface-container"
                        phx-click="select_node"
                        phx-value-node-id={client.node_id}
                      >
                        <td class="font-mono font-semibold">{client.node_id}</td>
                        <td>{client.hostname}</td>
                        <td class="font-mono text-sm">{client.ip}</td>
                        <td>
                          <.badge color="ghost" size="sm">{client.version}</.badge>
                        </td>
                        <td class="text-center">{length(client.interfaces)}</td>
                        <td class="text-center">{length(client.connections)}</td>
                        <td class="font-mono text-sm">{client.default_route || "-"}</td>
                        <td class="text-xs">
                          {Calendar.strftime(client.joined_at, "%Y-%m-%d %H:%M:%S")}
                        </td>
                        <td class="text-xs">
                          {Calendar.strftime(client.last_seen, "%H:%M:%S")}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Per-Client Details -->
        <%= for client <- @clients do %>
          <div class="card bg-surface shadow-xl">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <h2 class="card-title">
                  <.dm_mdi name="server-network" class="h-5 w-5" />
                  {client.hostname}
                  <.badge color="success" size="sm">Connected</.badge>
                </h2>
                <span class="font-mono text-sm text-on-surface-variant">{client.ip}</span>
              </div>

              <%= if client.interfaces != [] do %>
                <div class="mt-4">
                  <h3 class="text-sm font-semibold text-on-surface-variant mb-2">Interfaces</h3>
                  <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
                    <%= for iface <- client.interfaces do %>
                      <div class="bg-surface-container rounded-lg p-3">
                        <div class="font-mono font-semibold text-sm">{iface_name(iface)}</div>
                        <div class="text-xs text-on-surface-variant mt-1">{iface_detail(iface)}</div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if client.connections != [] do %>
                <div class="mt-4">
                  <h3 class="text-sm font-semibold text-on-surface-variant mb-2">Connections</h3>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <%= for conn <- client.connections do %>
                      <div class="bg-surface-container rounded-lg p-3">
                        <div class="flex items-center justify-between">
                          <span class="font-mono font-semibold text-sm">{conn_name(conn)}</span>
                          <.badge color={conn_state_color(conn)} size="sm">
                            {conn_state(conn)}
                          </.badge>
                        </div>
                        <div class="text-xs text-on-surface-variant mt-1">{conn_detail(conn)}</div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("toggle_docs", _params, socket) do
    {:noreply, assign(socket, :show_docs, !socket.assigns.show_docs)}
  end

  def handle_event("select_node", %{"node-id" => node_id}, socket) do
    {:noreply, push_navigate(socket, to: "/netman/#{node_id}")}
  end

  @impl true
  def handle_info({event, _client_info}, socket)
      when event in [:netman_joined, :netman_left, :netman_updated] do
    {:noreply, assign(socket, :clients, NetmanRegistry.list())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Helpers

  defp total_interfaces(clients) do
    Enum.sum(Enum.map(clients, fn c -> length(c.interfaces) end))
  end

  defp total_connections(clients) do
    Enum.sum(Enum.map(clients, fn c -> length(c.connections) end))
  end

  defp iface_name(iface) when is_map(iface), do: iface["name"] || iface["ifname"] || "unknown"
  defp iface_name(iface) when is_binary(iface), do: iface
  defp iface_name(_), do: "unknown"

  defp iface_detail(iface) when is_map(iface) do
    parts =
      [iface["address"], iface["operstate"]]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " · ")
  end

  defp iface_detail(_), do: ""

  defp conn_name(conn) when is_map(conn), do: conn["interface"] || conn["profile_id"] || "unknown"
  defp conn_name(conn) when is_binary(conn), do: conn
  defp conn_name(_), do: "unknown"

  defp conn_state(conn) when is_map(conn), do: conn["state"] || "unknown"
  defp conn_state(_), do: "unknown"

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

  defp conn_detail(conn) when is_map(conn) do
    parts =
      [conn["ip"], conn["profile_id"]]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " · ")
  end

  defp conn_detail(_), do: ""
end
