defmodule YellowDog.Console.NetbootLive.Index do
  @moduledoc "Netboot dashboard — overview of device states, TFTP status, recent activity."
  use YellowDog.Console, :live_view

  import YellowDog.Console.NetbootComponents
  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:devices")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:tftp")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Netboot Dashboard",
       connected: connected?(socket),
       service_running: service_running?(YellowDog.Netboot.TFTP.Server)
     )
     |> load_data()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <.service_alert :if={not @service_running} service="Netboot" navigate="/settings" />

        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-4xl font-bold">Netboot Dashboard</h1>
            <p class="mt-2 text-base-content/70">
              Network boot provisioning overview
            </p>
          </div>
          <div class="flex gap-2">
            <.link navigate="/netboot/log" class="btn btn-ghost btn-sm">
              Boot Log
            </.link>
            <button phx-click="refresh" class="btn btn-outline btn-sm">
              Refresh
            </button>
          </div>
        </div>

        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <.link
            navigate="/netboot/devices?state=discovered"
            class="stat hover:bg-base-200 transition-colors cursor-pointer"
          >
            <div class="stat-title">Discovered</div>
            <div class="stat-value text-base-content">{Map.get(@state_counts, :discovered, 0)}</div>
          </.link>
          <.link
            navigate="/netboot/devices?state=booting"
            class="stat hover:bg-base-200 transition-colors cursor-pointer"
          >
            <div class="stat-title">Booting</div>
            <div class="stat-value text-warning">{Map.get(@state_counts, :booting, 0)}</div>
          </.link>
          <.link
            navigate="/netboot/devices?state=installing"
            class="stat hover:bg-base-200 transition-colors cursor-pointer"
          >
            <div class="stat-title">Installing</div>
            <div class="stat-value text-info">{Map.get(@state_counts, :installing, 0)}</div>
          </.link>
          <.link
            navigate="/netboot/devices?state=installed"
            class="stat hover:bg-base-200 transition-colors cursor-pointer"
          >
            <div class="stat-title">Installed</div>
            <div class="stat-value text-success">{Map.get(@state_counts, :installed, 0)}</div>
          </.link>
          <.link
            navigate="/netboot/devices?state=failed"
            class="stat hover:bg-base-200 transition-colors cursor-pointer"
          >
            <div class="stat-title">Failed</div>
            <div class="stat-value text-error">{Map.get(@state_counts, :failed, 0)}</div>
          </.link>
        </div>

        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">TFTP Requests</div>
            <div class="stat-value text-primary">{@metrics.tftp_requests_accepted}</div>
            <div class="stat-desc">{@metrics.tftp_requests_rejected} rejected</div>
          </div>
          <div class="stat">
            <div class="stat-title">Transfers</div>
            <div class="stat-value">{@metrics.tftp_transfers_completed}</div>
            <div class="stat-desc">
              {max(
                @metrics.tftp_transfers_started - @metrics.tftp_transfers_completed -
                  @metrics.tftp_transfers_failed,
                0
              )} in progress, {@metrics.tftp_transfers_failed} failed
            </div>
          </div>
          <div class="stat">
            <div class="stat-title">Bytes Transferred</div>
            <div class="stat-value text-sm">{format_size(@metrics.tftp_bytes_transferred)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Boot Scripts</div>
            <div class="stat-value">{@metrics.boot_scripts_rendered}</div>
            <div class="stat-desc">iPXE scripts served</div>
          </div>
          <div class="stat">
            <div class="stat-title">Devices Discovered</div>
            <div class="stat-value">{@metrics.devices_discovered}</div>
            <div class="stat-desc">via DHCP/TFTP</div>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.card>
            <div class="flex items-center justify-between mb-4">
              <h2 class="card-title">TFTP Server</h2>
              <.link navigate="/netboot/tftp" class="link link-primary text-sm">Details</.link>
            </div>
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
            <div class="flex items-center justify-between mb-4">
              <h2 class="card-title">Boot Profiles</h2>
              <.link navigate="/netboot/profiles" class="link link-primary text-sm">View all</.link>
            </div>
            <div :if={@profiles == []} class="text-base-content/50">
              No profiles configured —
              <.link navigate="/netboot/profiles/new" class="link link-primary">create one</.link>
            </div>
            <div :for={profile <- @profiles} class="flex justify-between items-center py-1">
              <div>
                <.link
                  navigate={"/netboot/profiles/#{profile.id}/edit"}
                  class="link link-primary font-medium"
                >
                  {profile.id}
                </.link>
                <span :if={profile.description} class="text-base-content/70 text-sm ml-2">
                  {profile.description}
                </span>
              </div>
              <.badge color="ghost" size="sm">
                {Map.get(@profile_usage, profile.id, 0)} devices
              </.badge>
            </div>
          </.card>
        </div>

        <.card>
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">Recent Devices</h2>
            <.link navigate="/netboot/devices" class="link link-primary text-sm">View all</.link>
          </div>
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
                  <td>
                    <.link
                      :if={device.profile_id}
                      navigate={"/netboot/profiles/#{device.profile_id}/edit"}
                      class="link link-primary"
                    >
                      {device.profile_id}
                    </.link>
                    <span :if={!device.profile_id}>-</span>
                  </td>
                  <td class="text-sm" title={format_datetime_full(device.last_seen)}>
                    {format_time_ago(device.last_seen)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
        <div class="text-xs text-base-content/50 flex justify-end">
          <span :if={@connected} class="flex items-center gap-1">
            <span class="w-2 h-2 bg-success rounded-full animate-pulse"></span> Live
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:device_state_changed, _device}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:device_registered, _device}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, load_data(socket)}
  end

  @impl true
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

    profile_usage =
      devices
      |> Enum.filter(& &1.profile_id)
      |> Enum.frequencies_by(& &1.profile_id)

    metrics = load_metrics()

    socket
    |> assign(:state_counts, state_counts)
    |> assign(:tftp_status, tftp_status)
    |> assign(:profiles, profiles)
    |> assign(:recent_devices, recent)
    |> assign(:profile_usage, profile_usage)
    |> assign(:metrics, metrics)
  end

  defp load_metrics do
    YellowDog.Netboot.Metrics.all()
  rescue
    _ -> default_metrics()
  end

  defp default_metrics do
    %{
      tftp_requests_accepted: 0,
      tftp_requests_rejected: 0,
      tftp_transfers_started: 0,
      tftp_transfers_completed: 0,
      tftp_transfers_failed: 0,
      tftp_bytes_transferred: 0,
      devices_discovered: 0,
      boot_scripts_rendered: 0
    }
  end
end
