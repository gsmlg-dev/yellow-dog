defmodule YellowDog.Console.NetmanLive.NodeLive do
  @moduledoc """
  Overview page for a single connected Netman service instance.
  Shows summary of interfaces, connections, and default route.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.NetmanRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: NetmanRegistry.subscribe()
    {:ok, assign(socket, page_title: "Netman Node")}
  end

  @impl true
  def handle_params(%{"node_id" => node_id}, _uri, socket) do
    case NetmanRegistry.get(node_id) do
      {:ok, client} ->
        {:noreply,
         assign(socket,
           node_id: node_id,
           client: client,
           page_title: "#{client.hostname} — Network Manager"
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
        <div class="flex items-center justify-between">
          <div>
            <div class="flex items-center gap-2">
              <.link navigate="/netman" class="btn btn-ghost btn-sm btn-circle">
                <.dm_mdi name="arrow-left" class="w-5 h-5" />
              </.link>
              <h1 class="text-4xl font-bold">{@client.hostname}</h1>
              <.badge color="success" size="sm">Connected</.badge>
            </div>
            <p class="mt-2 text-on-surface-variant ml-10">
              <span class="font-mono text-sm">{@client.node_id}</span>
              · <span class="font-mono text-sm">{@client.ip}</span>
              · <span class="text-sm">v{@client.version}</span>
            </p>
          </div>
        </div>

        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <.card>
            <div class="text-sm text-on-surface-variant">Interfaces</div>
            <div class="text-2xl font-bold text-info">{length(@client.interfaces)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Connections</div>
            <div class="text-2xl font-bold text-success">{length(@client.connections)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Default Route</div>
            <div class="text-lg font-bold font-mono">{@client.default_route || "-"}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Connected Since</div>
            <div class="text-sm font-mono">
              {Calendar.strftime(@client.joined_at, "%Y-%m-%d %H:%M")}
            </div>
          </.card>
        </div>

        <!-- Quick Links -->
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <.link
            navigate={"/netman/#{@node_id}/interfaces"}
            class="card bg-surface shadow-xl hover:shadow-2xl transition-shadow cursor-pointer"
          >
            <div class="card-body items-center text-center">
              <.dm_mdi name="ethernet" class="w-10 h-10 text-info" />
              <h3 class="card-title text-base">Interfaces</h3>
              <p class="text-sm text-on-surface-variant">
                {length(@client.interfaces)} network interfaces
              </p>
            </div>
          </.link>
          <.link
            navigate={"/netman/#{@node_id}/resolved"}
            class="card bg-surface shadow-xl hover:shadow-2xl transition-shadow cursor-pointer"
          >
            <div class="card-body items-center text-center">
              <.dm_mdi name="dns" class="w-10 h-10 text-primary" />
              <h3 class="card-title text-base">Resolved Server</h3>
              <p class="text-sm text-on-surface-variant">DNS resolution status</p>
            </div>
          </.link>
          <.link
            navigate={"/netman/#{@node_id}/dhcp-client"}
            class="card bg-surface shadow-xl hover:shadow-2xl transition-shadow cursor-pointer"
          >
            <div class="card-body items-center text-center">
              <.dm_mdi name="chip" class="w-10 h-10 text-warning" />
              <h3 class="card-title text-base">DHCP Client</h3>
              <p class="text-sm text-on-surface-variant">
                {length(@client.connections)} active connections
              </p>
            </div>
          </.link>
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
end
