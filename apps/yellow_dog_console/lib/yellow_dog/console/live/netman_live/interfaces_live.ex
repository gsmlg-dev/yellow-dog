defmodule YellowDog.Console.NetmanLive.InterfacesLive do
  @moduledoc """
  Interfaces page for a connected Netman service instance.
  Shows detailed network interface information including addresses and routes.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.NetmanRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: NetmanRegistry.subscribe()
    {:ok, assign(socket, page_title: "Interfaces", selected: nil)}
  end

  @impl true
  def handle_params(%{"node_id" => node_id}, _uri, socket) do
    case NetmanRegistry.get(node_id) do
      {:ok, client} ->
        {:noreply,
         assign(socket,
           node_id: node_id,
           client: client,
           interfaces: client.interfaces,
           page_title: "#{client.hostname} — Interfaces"
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
            <h1 class="text-4xl font-bold">Interfaces</h1>
            <p class="mt-1 text-on-surface-variant">
              {@client.hostname} · <span class="font-mono text-sm">{@client.ip}</span>
            </p>
          </div>
        </div>
        <!-- Summary Stats -->
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <.card>
            <div class="text-sm text-on-surface-variant">Total Interfaces</div>
            <div class="text-2xl font-bold text-info">{length(@interfaces)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Up</div>
            <div class="text-2xl font-bold text-success">
              {Enum.count(@interfaces, &(ifield(&1, "state") == "up"))}
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">With Carrier</div>
            <div class="text-2xl font-bold text-primary">
              {Enum.count(@interfaces, &(ifield(&1, "carrier") == true))}
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">With Addresses</div>
            <div class="text-2xl font-bold text-warning">
              {Enum.count(@interfaces, &(length(ifield(&1, "addresses") || []) > 0))}
            </div>
          </.card>
        </div>
        <!-- Interface List -->
        <%= if @interfaces == [] do %>
          <div class="card bg-surface shadow-xl">
            <div class="card-body text-center py-12 text-on-surface-variant">
              <.dm_mdi name="ethernet-cable-off" class="h-16 w-16 mx-auto mb-4" />
              <p class="text-lg">No interfaces reported</p>
            </div>
          </div>
        <% else %>
          <div class="space-y-4">
            <%= for iface <- Enum.sort_by(@interfaces, &ifield(&1, "index")) do %>
              <div class="card bg-surface shadow-xl">
                <div class="card-body">
                  <!-- Interface Header -->
                  <div
                    class="flex items-center justify-between cursor-pointer"
                    phx-click="toggle_iface"
                    phx-value-name={ifield(iface, "name")}
                  >
                    <div class="flex items-center gap-3">
                      <.dm_mdi name={iface_icon(iface)} class="w-6 h-6 text-info" />
                      <div>
                        <span class="font-mono font-bold text-lg">{ifield(iface, "name")}</span>
                        <%= if ifield(iface, "kind") do %>
                          <.badge color="ghost" size="sm" class="ml-2">
                            {ifield(iface, "kind")}
                          </.badge>
                        <% end %>
                      </div>
                    </div>
                    <div class="flex items-center gap-2">
                      <.badge color={state_color(iface)} size="sm">
                        {ifield(iface, "state")}
                      </.badge>
                      <%= if ifield(iface, "carrier") == true do %>
                        <.badge color="success" size="sm">Carrier</.badge>
                      <% else %>
                        <.badge color="ghost" size="sm">No Carrier</.badge>
                      <% end %>
                      <.dm_mdi
                        name={
                          if @selected == ifield(iface, "name"),
                            do: "chevron-up",
                            else: "chevron-down"
                        }
                        class="w-5 h-5 text-on-surface-variant"
                      />
                    </div>
                  </div>
                  <!-- Interface Summary (always visible) -->
                  <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 mt-3">
                    <div>
                      <div class="text-xs text-on-surface-variant">MAC Address</div>
                      <div class="font-mono text-sm">{ifield(iface, "mac") || "-"}</div>
                    </div>
                    <div>
                      <div class="text-xs text-on-surface-variant">MTU</div>
                      <div class="font-mono text-sm">{ifield(iface, "mtu") || "-"}</div>
                    </div>
                    <div>
                      <div class="text-xs text-on-surface-variant">Index</div>
                      <div class="font-mono text-sm">{ifield(iface, "index") || "-"}</div>
                    </div>
                    <div>
                      <div class="text-xs text-on-surface-variant">Addresses</div>
                      <div class="font-mono text-sm">
                        {length(ifield(iface, "addresses") || [])} assigned
                      </div>
                    </div>
                  </div>
                  <!-- Expanded Detail -->
                  <%= if @selected == ifield(iface, "name") do %>
                    <div class="divider my-2"></div>
                    <!-- Addresses -->
                    <div>
                      <h3 class="text-sm font-semibold text-on-surface-variant mb-2">
                        <.dm_mdi name="ip-network" class="w-4 h-4 inline-block" /> Addresses
                      </h3>
                      <%= if (ifield(iface, "addresses") || []) == [] do %>
                        <p class="text-sm text-on-surface-variant pl-2">No addresses assigned</p>
                      <% else %>
                        <div class="overflow-x-auto">
                          <table class="table table-sm">
                            <thead>
                              <tr>
                                <th>Address</th>
                                <th>Prefix</th>
                                <th>Family</th>
                                <th>Scope</th>
                              </tr>
                            </thead>
                            <tbody>
                              <%= for addr <- ifield(iface, "addresses") || [] do %>
                                <tr>
                                  <td class="font-mono text-sm">{addr["address"]}</td>
                                  <td class="font-mono text-sm">/{addr["prefix_len"]}</td>
                                  <td>
                                    <.badge
                                      color={
                                        if addr["family"] == "inet6", do: "info", else: "primary"
                                      }
                                      size="sm"
                                    >
                                      {addr["family"]}
                                    </.badge>
                                  </td>
                                  <td>{addr["scope"]}</td>
                                </tr>
                              <% end %>
                            </tbody>
                          </table>
                        </div>
                      <% end %>
                    </div>
                    <!-- Routes -->
                    <div class="mt-4">
                      <h3 class="text-sm font-semibold text-on-surface-variant mb-2">
                        <.dm_mdi name="routes" class="w-4 h-4 inline-block" /> Routes
                      </h3>
                      <%= if (ifield(iface, "routes") || []) == [] do %>
                        <p class="text-sm text-on-surface-variant pl-2">No routes</p>
                      <% else %>
                        <div class="overflow-x-auto">
                          <table class="table table-sm">
                            <thead>
                              <tr>
                                <th>Destination</th>
                                <th>Gateway</th>
                                <th>Metric</th>
                                <th>Protocol</th>
                                <th>Family</th>
                              </tr>
                            </thead>
                            <tbody>
                              <%= for route <- ifield(iface, "routes") || [] do %>
                                <tr>
                                  <td class="font-mono text-sm">
                                    {route["destination"] || "default"}
                                  </td>
                                  <td class="font-mono text-sm">{route["gateway"] || "-"}</td>
                                  <td class="font-mono text-sm">{route["metric"]}</td>
                                  <td>{route["protocol"] || "-"}</td>
                                  <td>
                                    <.badge
                                      color={
                                        if route["family"] == "inet6", do: "info", else: "primary"
                                      }
                                      size="sm"
                                    >
                                      {route["family"]}
                                    </.badge>
                                  </td>
                                </tr>
                              <% end %>
                            </tbody>
                          </table>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("toggle_iface", %{"name" => name}, socket) do
    selected = if socket.assigns.selected == name, do: nil, else: name
    {:noreply, assign(socket, :selected, selected)}
  end

  @impl true
  def handle_info({event, %{node_id: node_id}}, socket)
      when event in [:netman_joined, :netman_updated] and node_id == socket.assigns.node_id do
    case NetmanRegistry.get(node_id) do
      {:ok, client} ->
        {:noreply, assign(socket, client: client, interfaces: client.interfaces)}

      :error ->
        {:noreply, push_navigate(socket, to: "/netman")}
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

  # Helpers

  defp ifield(iface, key) when is_map(iface), do: iface[key]
  defp ifield(_, _), do: nil

  defp state_color(iface) do
    case ifield(iface, "state") do
      "up" -> "success"
      "down" -> "error"
      _ -> "ghost"
    end
  end

  defp iface_icon(iface) do
    case ifield(iface, "kind") do
      "bridge" ->
        "bridge"

      "veth" ->
        "swap-horizontal"

      "vlan" ->
        "tag"

      "bond" ->
        "link-variant"

      "tun" ->
        "tunnel"

      "tap" ->
        "tunnel-outline"

      "wireguard" ->
        "shield-lock"

      _ ->
        case ifield(iface, "name") do
          "lo" -> "restart"
          <<"wl", _::binary>> -> "wifi"
          <<"wlan", _::binary>> -> "wifi"
          <<"docker", _::binary>> -> "docker"
          <<"veth", _::binary>> -> "swap-horizontal"
          <<"br-", _::binary>> -> "bridge"
          _ -> "ethernet"
        end
    end
  end
end
