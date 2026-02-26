defmodule YellowDog.Console.DhcpClientLive.InterfacesLive do
  @moduledoc """
  LiveView for detailed DHCP client interface management.

  Shows per-interface state machine details, packet counters, and
  allows starting/stopping interface clients.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.FormatHelper
  import YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :telemetry.attach(
        "dhcp-client-ifaces-#{inspect(self())}",
        [:yellow_dog, :dhcp_client, :state, :change],
        &handle_telemetry/4,
        %{pid: self()}
      )
    end

    {:ok,
     socket
     |> assign(
       page_title: "DHCP Client Interfaces",
       interfaces: load_interfaces(),
       config: load_config()
     )}
  end

  @impl true
  def handle_info({:telemetry_event, _event, _measurements, _metadata}, socket) do
    {:noreply, assign(socket, :interfaces, load_interfaces())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("dhcp-client-ifaces-#{inspect(self())}")
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-4xl font-bold">DHCP Client Interfaces</h1>
        <p class="mt-2 text-base-content/70">Manage per-interface DHCP client instances</p>
      </div>

      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title">Configuration</h2>
          <p class="text-sm text-base-content/70">
            Interfaces are configured in the TOML config file under [dhcp_client].
          </p>

          <%= if @config == %{} do %>
            <div class="alert alert-warning">
              <span>No DHCP client configuration found.</span>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table">
                <thead>
                  <tr>
                    <th>Interface</th>
                    <th>Mode</th>
                    <th>DAD</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for {iface_name, cfg} <- @config do %>
                    <tr>
                      <td class="font-mono">{iface_name}</td>
                      <td>
                        <span class="badge badge-outline">
                          {Map.get(cfg, :mode, :standalone)}
                        </span>
                      </td>
                      <td>
                        <%= if Map.get(cfg, :dad_enabled, true) do %>
                          <span class="badge badge-success badge-sm">Enabled</span>
                        <% else %>
                          <span class="badge badge-ghost badge-sm">Disabled</span>
                        <% end %>
                      </td>
                      <td>
                        <%= if interface_running?(iface_name, @interfaces) do %>
                          <span class="badge badge-success">Running</span>
                        <% else %>
                          <span class="badge badge-ghost">Stopped</span>
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
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title font-mono">{iface.interface}</h2>
              <span class={"badge #{state_badge(iface.state)}"}>{iface.state}</span>
            </div>

            <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-4">
              <div>
                <div class="text-xs font-semibold text-base-content/50 uppercase">State</div>
                <div class="text-lg font-bold">{iface.state}</div>
              </div>
              <div>
                <div class="text-xs font-semibold text-base-content/50 uppercase">IP</div>
                <div class="font-mono">
                  {if iface.lease, do: format_ip(iface.lease.ip), else: "Pending"}
                </div>
              </div>
              <div>
                <div class="text-xs font-semibold text-base-content/50 uppercase">Server</div>
                <div class="font-mono text-sm">
                  {if iface.lease, do: format_ip(iface.lease.server_ip), else: "-"}
                </div>
              </div>
              <div>
                <div class="text-xs font-semibold text-base-content/50 uppercase">XID</div>
                <div class="font-mono text-sm">
                  {if iface.lease, do: "0x#{Integer.to_string(iface.lease.xid, 16)}", else: "-"}
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp load_interfaces do
    case safe_call(YellowDog.DhcpClient, fn -> YellowDog.DhcpClient.all_statuses() end, []) do
      interfaces when is_list(interfaces) -> interfaces
      _ -> []
    end
  end

  defp load_config do
    safe_call(YellowDog.DhcpClient.Config, fn -> YellowDog.DhcpClient.Config.load_all() end, %{})
  end

  defp interface_running?(name, interfaces) do
    Enum.any?(interfaces, &(&1.interface == to_string(name)))
  end

  defp state_badge(:bound), do: "badge-success"
  defp state_badge(:renewing), do: "badge-info"
  defp state_badge(:rebinding), do: "badge-warning"
  defp state_badge(_), do: "badge-ghost"

  defp handle_telemetry(_event, _measurements, _metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, nil, nil, nil})
  end
end
