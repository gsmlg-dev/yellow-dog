defmodule YellowDog.Console.NetmanLive.DashboardLive do
  @moduledoc """
  Netman dashboard — shows network manager status, active connections,
  interfaces, and the current default route.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.FormatHelper
  import YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Network Manager")
     |> load_data()}
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
              Manage network connections, interfaces, and profiles
            </p>
          </div>
          <div class="flex items-center gap-3">
            <.status_indicator
              status={if @status.running, do: "running", else: "stopped"}
              label={if @status.running, do: "Running", else: "Stopped"}
              pulse
            />
            <button phx-click="refresh" class="btn btn-ghost btn-circle btn-sm" aria-label="Refresh">
              <.dm_mdi name="refresh" class="h-5 w-5" />
            </button>
          </div>
        </div>
        
    <!-- Summary Stats -->
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <.card>
            <div class="text-sm text-on-surface-variant">Interfaces</div>
            <div class="text-2xl font-bold text-primary">{length(@status.interfaces)}</div>
            <div class="text-xs text-on-surface-variant">Kernel links</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Connections</div>
            <div class="text-2xl font-bold text-info">{length(@status.connections)}</div>
            <div class="text-xs text-on-surface-variant">Active FSMs</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Profiles</div>
            <div class="text-2xl font-bold text-secondary">{length(@profiles)}</div>
            <div class="text-xs text-on-surface-variant">Configured</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Default Route</div>
            <div class="text-lg font-bold text-success font-mono">
              {format_default_route(@status.default_route)}
            </div>
            <div class="text-xs text-on-surface-variant">Gateway</div>
          </.card>
        </div>
        
    <!-- Active Connections -->
        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Active Connections</h2>

            <%= if @status.connections == [] do %>
              <div class="text-center py-8 text-on-surface-variant">
                <.dm_mdi name="lan-disconnect" class="h-12 w-12 mx-auto mb-2" />
                <p class="text-lg">No active connections</p>
                <p class="text-sm mt-1">Connections will appear when profiles are activated</p>
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
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for conn <- @status.connections do %>
                      <tr>
                        <td class="font-mono font-semibold">{conn[:interface] || "-"}</td>
                        <td class="text-sm">{conn[:profile_id] || "-"}</td>
                        <td>
                          <span class={"badge #{connection_state_badge(conn[:state])}"}>
                            {conn[:state] || "unknown"}
                          </span>
                        </td>
                        <td class="font-mono text-sm">
                          {format_connection_ip(conn)}
                        </td>
                        <td class="font-mono text-sm">
                          {format_connection_gateway(conn)}
                        </td>
                        <td>
                          <%= if conn[:state] in [:activated, :ip_check, :configuring, :prepare] do %>
                            <button
                              phx-click="deactivate"
                              phx-value-profile={conn[:profile_id]}
                              class="btn btn-error btn-xs"
                              data-confirm={"Deactivate connection #{conn[:profile_id]}?"}
                            >
                              Deactivate
                            </button>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Profiles -->
        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Connection Profiles</h2>

            <%= if @profiles == [] do %>
              <div class="text-center py-8 text-on-surface-variant">
                <p class="text-lg">No profiles configured</p>
                <p class="text-sm mt-1">Import TOML profile files to manage connections</p>
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-striped">
                  <thead>
                    <tr>
                      <th>Profile ID</th>
                      <th>Type</th>
                      <th>Interface</th>
                      <th>Autoconnect</th>
                      <th>Priority</th>
                      <th>IPv4</th>
                      <th>IPv6</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for profile <- @profiles do %>
                      <tr>
                        <td class="font-mono font-semibold">{profile.id}</td>
                        <td>
                          <span class="badge badge-outline">{profile.type}</span>
                        </td>
                        <td class="font-mono text-sm">{profile.interface || "*"}</td>
                        <td>
                          <%= if profile.autoconnect do %>
                            <span class="badge badge-success badge-sm">Yes</span>
                          <% else %>
                            <span class="badge badge-ghost badge-sm">No</span>
                          <% end %>
                        </td>
                        <td class="text-center">{profile.autoconnect_priority}</td>
                        <td class="text-sm">{format_ip_method(profile.ipv4)}</td>
                        <td class="text-sm">{format_ip_method(profile.ipv6)}</td>
                        <td>
                          <%= if not profile_active?(profile.id, @status.connections) do %>
                            <button
                              phx-click="activate"
                              phx-value-profile={profile.id}
                              class="btn btn-success btn-xs"
                            >
                              Activate
                            </button>
                          <% else %>
                            <span class="badge badge-info badge-sm">Active</span>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Kernel Interfaces -->
        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Network Interfaces</h2>

            <%= if @status.interfaces == [] do %>
              <div class="text-center py-8 text-on-surface-variant">
                <p>No network interfaces detected</p>
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-striped">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>State</th>
                      <th>Carrier</th>
                      <th>MAC Address</th>
                      <th>MTU</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for iface <- @status.interfaces do %>
                      <tr>
                        <td class="font-mono font-semibold">{iface[:name] || iface[:ifname]}</td>
                        <td>
                          <span class={"badge #{link_state_badge(iface[:operstate])}"}>
                            {iface[:operstate] || "unknown"}
                          </span>
                        </td>
                        <td>
                          <%= if iface[:carrier] do %>
                            <span class="badge badge-success badge-sm">Up</span>
                          <% else %>
                            <span class="badge badge-ghost badge-sm">Down</span>
                          <% end %>
                        </td>
                        <td class="font-mono text-sm">{iface[:address] || "-"}</td>
                        <td>{iface[:mtu] || "-"}</td>
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
  def handle_event("refresh", _params, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_event("activate", %{"profile" => profile_id}, socket) do
    case safe_call(YellowDog.Netman, fn -> YellowDog.Netman.activate(profile_id) end, :error) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Profile #{profile_id} activated")
         |> load_data()}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to activate profile #{profile_id}")}
    end
  end

  def handle_event("deactivate", %{"profile" => profile_id}, socket) do
    case safe_call(YellowDog.Netman, fn -> YellowDog.Netman.deactivate(profile_id) end, :error) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Profile #{profile_id} deactivated")
         |> load_data()}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to deactivate profile #{profile_id}")}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_data(socket) do
    status =
      safe_call(YellowDog.Netman, fn -> YellowDog.Netman.status() end, %{
        running: false,
        interfaces: [],
        connections: [],
        default_route: :none
      })

    profiles =
      safe_call(YellowDog.Netman, fn -> YellowDog.Netman.list_profiles() end, [])

    socket
    |> assign(:status, status)
    |> assign(:profiles, profiles)
  end

  defp format_default_route({:ok, conn_id}), do: conn_id
  defp format_default_route(:none), do: "None"
  defp format_default_route(_), do: "-"

  defp connection_state_badge(:activated), do: "badge-success"
  defp connection_state_badge(:ip_check), do: "badge-info"
  defp connection_state_badge(:configuring), do: "badge-warning"
  defp connection_state_badge(:prepare), do: "badge-warning"
  defp connection_state_badge(:disconnected), do: "badge-ghost"
  defp connection_state_badge(:unavailable), do: "badge-error"
  defp connection_state_badge(_), do: "badge-ghost"

  defp link_state_badge(:up), do: "badge-success"
  defp link_state_badge("up"), do: "badge-success"
  defp link_state_badge(:down), do: "badge-error"
  defp link_state_badge("down"), do: "badge-error"
  defp link_state_badge(_), do: "badge-ghost"

  defp format_connection_ip(conn) do
    case conn[:lease] do
      %{ip: ip} when not is_nil(ip) -> format_ip(ip)
      _ -> conn[:ip] || "-"
    end
  end

  defp format_connection_gateway(conn) do
    case conn[:lease] do
      %{gateway: gw} when not is_nil(gw) -> format_ip(gw)
      _ -> "-"
    end
  end

  defp format_ip_method(%{method: method}), do: to_string(method)
  defp format_ip_method(_), do: "-"

  defp profile_active?(profile_id, connections) do
    Enum.any?(connections, fn c -> c[:profile_id] == profile_id end)
  end
end
