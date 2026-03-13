defmodule YellowDog.Console.NetmanLive.ResolvedLive do
  @moduledoc """
  Resolved server page for a connected Netman service instance.
  Shows DNS resolution configuration and status.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.NetmanRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: NetmanRegistry.subscribe()
    {:ok, assign(socket, page_title: "Resolved Server")}
  end

  @impl true
  def handle_params(%{"node_id" => node_id}, _uri, socket) do
    case NetmanRegistry.get(node_id) do
      {:ok, client} ->
        {:noreply,
         assign(socket,
           node_id: node_id,
           client: client,
           page_title: "#{client.hostname} — Resolved Server"
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
            <h1 class="text-4xl font-bold">Resolved Server</h1>
            <p class="mt-1 text-on-surface-variant">
              {@client.hostname} · <span class="font-mono text-sm">{@client.ip}</span>
            </p>
          </div>
        </div>

        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title">DNS Resolution</h2>
            <p class="text-on-surface-variant">
              DNS resolver status for this Netman instance.
              Resolved server data will appear here when the remote client reports it.
            </p>

            <%= if resolved_info = @client[:resolved] do %>
              <div class="mt-4 space-y-3">
                <%= if upstreams = resolved_info["upstreams"] do %>
                  <div>
                    <h3 class="text-sm font-semibold text-on-surface-variant mb-2">
                      Upstream Servers
                    </h3>
                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                      <%= for upstream <- upstreams do %>
                        <div class="bg-surface-container rounded-lg p-3 font-mono text-sm">
                          {upstream}
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%= if cache = resolved_info["cache"] do %>
                  <div>
                    <h3 class="text-sm font-semibold text-on-surface-variant mb-2">Cache Stats</h3>
                    <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
                      <.card>
                        <div class="text-xs text-on-surface-variant">Entries</div>
                        <div class="text-lg font-bold">{cache["entries"] || 0}</div>
                      </.card>
                      <.card>
                        <div class="text-xs text-on-surface-variant">Hits</div>
                        <div class="text-lg font-bold text-success">{cache["hits"] || 0}</div>
                      </.card>
                      <.card>
                        <div class="text-xs text-on-surface-variant">Misses</div>
                        <div class="text-lg font-bold text-warning">{cache["misses"] || 0}</div>
                      </.card>
                    </div>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div class="text-center py-8 text-on-surface-variant mt-4">
                <.dm_mdi name="dns" class="h-12 w-12 mx-auto mb-3" />
                <p>No resolved server data reported by this node</p>
                <p class="text-sm mt-1">
                  The remote client needs to include <code class="text-primary">resolved</code>
                  in its status payload
                </p>
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
end
