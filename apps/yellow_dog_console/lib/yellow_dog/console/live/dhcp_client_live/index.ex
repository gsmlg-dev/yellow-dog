defmodule YellowDog.Console.DhcpClientLive.Index do
  @moduledoc """
  LiveView for DHCP Client overview and monitoring.

  Displays the status of all managed interfaces, current leases,
  and state machine status with real-time telemetry updates.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.FormatHelper
  import YellowDog.Console.ServiceHelper

  @telemetry_events [
    [:yellow_dog, :dhcp_client, :state, :change],
    [:yellow_dog, :dhcp_client, :lease, :bound],
    [:yellow_dog, :dhcp_client, :lease, :renewed],
    [:yellow_dog, :dhcp_client, :lease, :expired]
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      handler_id = "dhcp-client-overview-#{inspect(self())}"

      for event <- @telemetry_events do
        :telemetry.attach(handler_id <> inspect(event), event, &handle_telemetry/4, %{
          pid: self()
        })
      end
    end

    {:ok,
     socket
     |> assign(
       page_title: "DHCP Client",
       interfaces: load_interfaces(),
       recent_events: []
     )}
  end

  @impl true
  def handle_info({:telemetry_event, _event, _measurements, _metadata}, socket) do
    {:noreply, assign(socket, :interfaces, load_interfaces())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    handler_id = "dhcp-client-overview-#{inspect(self())}"

    for event <- @telemetry_events do
      :telemetry.detach(handler_id <> inspect(event))
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-4xl font-bold">DHCP Client</h1>
          <p class="mt-2 text-base-content/70">
            Manage DHCP client interfaces and monitor lease status
          </p>
        </div>
      </div>

      <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
        <div class="stat">
          <div class="stat-title">Interfaces</div>
          <div class="stat-value text-primary">{length(@interfaces)}</div>
          <div class="stat-desc">Managed DHCP clients</div>
        </div>
        <div class="stat">
          <div class="stat-title">Bound</div>
          <div class="stat-value text-success">{count_by_state(@interfaces, :bound)}</div>
          <div class="stat-desc">With active leases</div>
        </div>
        <div class="stat">
          <div class="stat-title">Requesting</div>
          <div class="stat-value text-warning">
            {count_by_state(@interfaces, :init) + count_by_state(@interfaces, :selecting) +
              count_by_state(@interfaces, :requesting)}
          </div>
          <div class="stat-desc">Acquiring addresses</div>
        </div>
        <div class="stat">
          <div class="stat-title">Renewing</div>
          <div class="stat-value text-info">
            {count_by_state(@interfaces, :renewing) + count_by_state(@interfaces, :rebinding)}
          </div>
          <div class="stat-desc">Extending leases</div>
        </div>
      </div>

      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title">Interface Status</h2>

          <%= if @interfaces == [] do %>
            <div class="text-center py-12 text-base-content/50">
              <p class="text-lg">No DHCP client interfaces configured</p>
              <p class="text-sm mt-2">
                Configure interfaces in the TOML config under [dhcp_client]
              </p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>Interface</th>
                    <th>State</th>
                    <th>IP Address</th>
                    <th>Server</th>
                    <th>Lease Time</th>
                    <th>YellowDog</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for iface <- @interfaces do %>
                    <tr>
                      <td class="font-mono font-semibold">{iface.interface}</td>
                      <td>
                        <span class={"badge #{state_badge_class(iface.state)}"}>
                          {iface.state}
                        </span>
                      </td>
                      <td class="font-mono">
                        {if iface.lease, do: format_ip(iface.lease.ip), else: "-"}
                      </td>
                      <td class="font-mono text-sm">
                        {if iface.lease, do: format_ip(iface.lease.server_ip), else: "-"}
                      </td>
                      <td>
                        {if iface.lease, do: format_lease_time(iface.lease.lease_time), else: "-"}
                      </td>
                      <td>
                        <%= if iface.lease && iface.lease.yellowdog_server do %>
                          <span class="badge badge-success badge-sm">YD</span>
                        <% else %>
                          <span class="badge badge-ghost badge-sm">-</span>
                        <% end %>
                      </td>
                      <td>
                        <%= if iface.state in [:bound, :renewing, :rebinding] do %>
                          <button
                            phx-click="release"
                            phx-value-interface={iface.interface}
                            class="btn btn-error btn-xs"
                            data-confirm="Release lease for this interface?"
                          >
                            Release
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

      <%= for iface <- @interfaces do %>
        <%= if iface.lease do %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">
                Lease Details — {iface.interface}
                <%= if iface.lease.yellowdog_server do %>
                  <span class="badge badge-success">YellowDog Server</span>
                <% end %>
              </h2>

              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <div>
                  <div class="text-sm font-semibold text-base-content/70">IP Address</div>
                  <div class="font-mono">{format_ip(iface.lease.ip)}</div>
                </div>
                <div>
                  <div class="text-sm font-semibold text-base-content/70">Subnet Mask</div>
                  <div class="font-mono">{format_ip(iface.lease.subnet_mask)}</div>
                </div>
                <div>
                  <div class="text-sm font-semibold text-base-content/70">Router</div>
                  <div class="font-mono">
                    {if iface.lease.router, do: format_ip(iface.lease.router), else: "None"}
                  </div>
                </div>
                <div>
                  <div class="text-sm font-semibold text-base-content/70">DNS Servers</div>
                  <div class="font-mono text-sm">
                    {Enum.map_join(iface.lease.dns_servers, ", ", &format_ip/1)}
                  </div>
                </div>
                <div>
                  <div class="text-sm font-semibold text-base-content/70">DHCP Server</div>
                  <div class="font-mono">{format_ip(iface.lease.server_ip)}</div>
                </div>
                <div>
                  <div class="text-sm font-semibold text-base-content/70">Domain</div>
                  <div>{iface.lease.domain_name || "None"}</div>
                </div>
                <div>
                  <div class="text-sm font-semibold text-base-content/70">Lease Time</div>
                  <div>{format_lease_time(iface.lease.lease_time)}</div>
                </div>
                <div>
                  <div class="text-sm font-semibold text-base-content/70">T1 (Renew)</div>
                  <div>{format_lease_time(iface.lease.t1)}</div>
                </div>
                <div>
                  <div class="text-sm font-semibold text-base-content/70">T2 (Rebind)</div>
                  <div>{format_lease_time(iface.lease.t2)}</div>
                </div>
                <div>
                  <div class="text-sm font-semibold text-base-content/70">Time Remaining</div>
                  <div>{format_lease_remaining(iface.lease)}</div>
                </div>
                <div>
                  <div class="text-sm font-semibold text-base-content/70">Obtained At</div>
                  <div class="text-sm">
                    {if iface.lease.obtained_at,
                      do: Calendar.strftime(iface.lease.obtained_at, "%Y-%m-%d %H:%M:%S UTC"),
                      else: "-"}
                  </div>
                </div>

                <%= if iface.lease.mtu do %>
                  <div>
                    <div class="text-sm font-semibold text-base-content/70">MTU</div>
                    <div>{iface.lease.mtu}</div>
                  </div>
                <% end %>

                <%= if iface.lease.ntp_servers != [] do %>
                  <div>
                    <div class="text-sm font-semibold text-base-content/70">NTP Servers</div>
                    <div class="font-mono text-sm">
                      {Enum.map_join(iface.lease.ntp_servers, ", ", &format_ip/1)}
                    </div>
                  </div>
                <% end %>

                <%= if iface.lease.control_url do %>
                  <div class="col-span-full">
                    <div class="text-sm font-semibold text-base-content/70">Control URL</div>
                    <div class="font-mono text-sm">{iface.lease.control_url}</div>
                  </div>
                <% end %>

                <%= if iface.lease.control_url_fallback do %>
                  <div class="col-span-full">
                    <div class="text-sm font-semibold text-base-content/70">
                      Control URL (Fallback)
                    </div>
                    <div class="font-mono text-sm">{iface.lease.control_url_fallback}</div>
                  </div>
                <% end %>

                <%= if iface.lease.cluster_id do %>
                  <div>
                    <div class="text-sm font-semibold text-base-content/70">Cluster ID</div>
                    <div class="font-mono text-sm">{iface.lease.cluster_id}</div>
                  </div>
                <% end %>

                <%= if iface.lease.server_id do %>
                  <div>
                    <div class="text-sm font-semibold text-base-content/70">Server ID</div>
                    <div class="font-mono text-sm">{iface.lease.server_id}</div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("release", %{"interface" => interface}, socket) do
    case safe_call(
           YellowDog.DhcpClient,
           fn -> YellowDog.DhcpClient.release(interface) end,
           :error
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Lease released for #{interface}")
         |> assign(:interfaces, load_interfaces())}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to release lease")}
    end
  end

  defp load_interfaces do
    case safe_call(YellowDog.DhcpClient, fn -> YellowDog.DhcpClient.all_statuses() end, []) do
      interfaces when is_list(interfaces) -> interfaces
      _ -> []
    end
  end

  defp count_by_state(interfaces, state) do
    Enum.count(interfaces, &(&1.state == state))
  end

  defp state_badge_class(:bound), do: "badge-success"
  defp state_badge_class(:renewing), do: "badge-info"
  defp state_badge_class(:rebinding), do: "badge-warning"
  defp state_badge_class(:init), do: "badge-ghost"
  defp state_badge_class(:selecting), do: "badge-ghost"
  defp state_badge_class(:requesting), do: "badge-warning"
  defp state_badge_class(_), do: "badge-ghost"

  defp format_lease_remaining(lease) do
    case YellowDog.DhcpClient.Lease.time_remaining(lease) do
      nil -> "-"
      0 -> "Expired"
      remaining -> format_lease_time(remaining)
    end
  end

  defp format_lease_time(nil), do: "-"
  defp format_lease_time(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_lease_time(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"

  defp format_lease_time(seconds) when seconds < 86400,
    do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp format_lease_time(seconds),
    do: "#{div(seconds, 86400)}d #{div(rem(seconds, 86400), 3600)}h"

  defp handle_telemetry(_event, _measurements, _metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, nil, nil, nil})
  end
end
