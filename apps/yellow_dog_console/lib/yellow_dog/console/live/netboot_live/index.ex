defmodule YellowDog.Console.NetbootLive.Index do
  @moduledoc "Netboot dashboard — overview of device states, TFTP status, recent activity."
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:devices")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:tftp")
    end

    {:ok,
     socket
     |> assign(page_title: "Netboot Dashboard")
     |> load_data()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div>
          <h1 class="text-4xl font-bold">Netboot Dashboard</h1>
          <p class="mt-2 text-base-content/70">
            Network boot provisioning overview
          </p>
        </div>

        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Discovered</div>
            <div class="stat-value text-base-content">{Map.get(@state_counts, :discovered, 0)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Booting</div>
            <div class="stat-value text-warning">{Map.get(@state_counts, :booting, 0)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Installing</div>
            <div class="stat-value text-info">{Map.get(@state_counts, :installing, 0)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Installed</div>
            <div class="stat-value text-success">{Map.get(@state_counts, :installed, 0)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Failed</div>
            <div class="stat-value text-error">{Map.get(@state_counts, :failed, 0)}</div>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.card>
            <h2 class="card-title mb-4">TFTP Server</h2>
            <div class="space-y-2">
              <div class="flex justify-between">
                <span class="text-base-content/70">Status</span>
                <.badge :if={@tftp_status.running} color="success" size="sm">Running</.badge>
                <.badge :if={!@tftp_status.running} color="error" size="sm">Stopped</.badge>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/70">Port</span>
                <span class="font-mono">{@tftp_status.port}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/70">Files Indexed</span>
                <span>{@tftp_status.file_count}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/70">Active Transfers</span>
                <span>{@tftp_status.active_transfers}</span>
              </div>
            </div>
          </.card>

          <.card>
            <h2 class="card-title mb-4">Boot Profiles</h2>
            <div :if={@profiles == []} class="text-base-content/50">No profiles configured</div>
            <div :for={profile <- @profiles} class="flex justify-between py-1">
              <span class="font-medium">{profile.id}</span>
              <span class="text-base-content/70 text-sm">{profile.description}</span>
            </div>
          </.card>
        </div>

        <.card>
          <h2 class="card-title mb-4">Recent Devices</h2>
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>MAC</th>
                  <th>Hostname</th>
                  <th>State</th>
                  <th>Profile</th>
                  <th>Last Seen</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@recent_devices == []}>
                  <td colspan="5" class="text-center text-base-content/50 py-8">
                    No netboot devices discovered yet
                  </td>
                </tr>
                <tr :for={device <- @recent_devices}>
                  <td class="font-mono text-sm">
                    <.link navigate={"/netboot/devices/#{device.mac}"} class="link link-primary">
                      {device.mac}
                    </.link>
                  </td>
                  <td>{device.hostname || "-"}</td>
                  <td><.state_badge state={device.state} /></td>
                  <td>{device.profile_id || "-"}</td>
                  <td class="text-sm">{format_datetime(device.last_seen)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp state_badge(assigns) do
    {color, label} = state_display(assigns.state)
    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <.badge color={@color} size="sm">{@label}</.badge>
    """
  end

  defp state_display(:discovered), do: {"neutral", "Discovered"}
  defp state_display(:booting), do: {"warning", "Booting"}
  defp state_display(:installing), do: {"info", "Installing"}
  defp state_display(:installed), do: {"success", "Installed"}
  defp state_display(:failed), do: {"error", "Failed"}
  defp state_display(:reinstall_requested), do: {"warning", "Reinstall"}
  defp state_display(_), do: {"neutral", "Unknown"}

  @impl true
  def handle_info({:device_state_changed, _device}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info({:device_registered, _device}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_data(socket) do
    devices =
      safe_call(
        YellowDog.Netboot.Device.Registry,
        fn ->
          YellowDog.Netboot.Device.Registry.list()
        end,
        []
      )

    state_counts =
      safe_call(
        YellowDog.Netboot.Device.Registry,
        fn ->
          YellowDog.Netboot.Device.Registry.count_by_state()
        end,
        %{}
      )

    tftp_status =
      safe_call(
        YellowDog.Netboot.TFTP.Server,
        fn ->
          YellowDog.Netboot.TFTP.Server.status()
        end,
        %{running: false, port: 69, file_count: 0, active_transfers: 0}
      )

    profiles =
      safe_call(
        YellowDog.Netboot.Manifest.Store,
        fn ->
          YellowDog.Netboot.Manifest.Store.list_profiles()
        end,
        []
      )

    recent =
      devices
      |> Enum.sort_by(& &1.last_seen, {:desc, DateTime})
      |> Enum.take(10)

    socket
    |> assign(:state_counts, state_counts)
    |> assign(:tftp_status, tftp_status)
    |> assign(:profiles, profiles)
    |> assign(:recent_devices, recent)
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
end
