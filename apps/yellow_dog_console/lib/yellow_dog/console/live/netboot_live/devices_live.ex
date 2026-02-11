defmodule YellowDog.Console.NetbootLive.DevicesLive do
  @moduledoc "Netboot device list — tracks discovered PXE devices and their states."
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:devices")
    end

    {:ok,
     socket
     |> assign(
       page_title: "Netboot Devices",
       search_query: "",
       filter_state: "all"
     )
     |> load_devices()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-4xl font-bold">Netboot Devices</h1>
            <p class="mt-2 text-base-content/70">
              PXE boot devices discovered via DHCP and TFTP
            </p>
          </div>
          <button
            phx-click="export_csv"
            id="export-csv"
            phx-hook="CsvDownload"
            class="btn btn-outline btn-sm"
          >
            Export CSV
          </button>
        </div>

        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Total Devices</div>
            <div class="stat-value text-primary">{length(@all_devices)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Installed</div>
            <div class="stat-value text-success">{@installed_count}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Failed</div>
            <div class="stat-value text-error">{@failed_count}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Showing</div>
            <div class="stat-value text-sm">{length(@filtered_devices)}</div>
          </div>
        </div>

        <.card>
          <div class="flex flex-col md:flex-row gap-4">
            <div class="flex-1">
              <label class="input input-bordered flex items-center gap-2">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  viewBox="0 0 16 16"
                  fill="currentColor"
                  class="h-4 w-4 opacity-70"
                >
                  <path
                    fill-rule="evenodd"
                    d="M9.965 11.026a5 5 0 1 1 1.06-1.06l2.755 2.754a.75.75 0 1 1-1.06 1.06l-2.755-2.754ZM10.5 7a3.5 3.5 0 1 1-7 0 3.5 3.5 0 0 1 7 0Z"
                    clip-rule="evenodd"
                  />
                </svg>
                <input
                  type="text"
                  class="grow"
                  placeholder="Search by MAC, hostname, or profile..."
                  value={@search_query}
                  phx-change="search"
                  phx-debounce="300"
                  name="search"
                />
              </label>
            </div>
            <select
              class="select select-bordered"
              phx-change="filter_state"
              name="state"
              value={@filter_state}
            >
              <option value="all">All States</option>
              <option :for={s <- @available_states} value={s}>{s}</option>
            </select>
          </div>
        </.card>

        <.card>
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>MAC Address</th>
                  <th>Hostname</th>
                  <th>Arch</th>
                  <th>Profile</th>
                  <th>State</th>
                  <th>Install Attempts</th>
                  <th>Last Seen</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@filtered_devices == []}>
                  <td colspan="7" class="text-center text-base-content/50 py-8">
                    No devices found
                  </td>
                </tr>
                <tr :for={device <- @filtered_devices}>
                  <td class="font-mono text-sm">
                    <.link navigate={"/netboot/devices/#{device.mac}"} class="link link-primary">
                      {device.mac}
                    </.link>
                  </td>
                  <td>{device.hostname || "-"}</td>
                  <td>{if device.arch, do: to_string(device.arch), else: "-"}</td>
                  <td>{device.profile_id || "-"}</td>
                  <td><.state_badge state={device.state} /></td>
                  <td>{device.install_attempts}</td>
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
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> apply_filters()}
  end

  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply, socket |> assign(:filter_state, state) |> apply_filters()}
  end

  def handle_event("export_csv", _params, socket) do
    csv = build_csv(socket.assigns.filtered_devices)
    filename = "netboot_devices_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info({:device_state_changed, _}, socket), do: {:noreply, load_devices(socket)}
  def handle_info({:device_registered, _}, socket), do: {:noreply, load_devices(socket)}
  def handle_info({:device_deleted, _}, socket), do: {:noreply, load_devices(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_devices(socket) do
    all =
      safe_call(
        YellowDog.Netboot.Device.Registry,
        fn ->
          YellowDog.Netboot.Device.Registry.list()
        end,
        []
      )

    states =
      all
      |> Enum.map(&to_string(&1.state))
      |> Enum.uniq()
      |> Enum.sort()

    socket
    |> assign(:all_devices, all)
    |> assign(:installed_count, Enum.count(all, &(&1.state == :installed)))
    |> assign(:failed_count, Enum.count(all, &(&1.state == :failed)))
    |> assign(:available_states, states)
    |> apply_filters()
  end

  defp apply_filters(socket) do
    devices =
      socket.assigns.all_devices
      |> filter_by_search(socket.assigns.search_query)
      |> filter_by_state(socket.assigns.filter_state)

    assign(socket, :filtered_devices, devices)
  end

  def filter_by_search(devices, ""), do: devices

  def filter_by_search(devices, query) do
    q = String.downcase(query)

    Enum.filter(devices, fn d ->
      String.contains?(String.downcase(d.mac), q) ||
        (d.hostname && String.contains?(String.downcase(d.hostname), q)) ||
        (d.profile_id && String.contains?(String.downcase(d.profile_id), q))
    end)
  end

  def filter_by_state(devices, "all"), do: devices
  def filter_by_state(devices, state), do: Enum.filter(devices, &(to_string(&1.state) == state))

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp build_csv(devices) do
    header = "MAC,Hostname,Arch,Profile,State,Install Attempts,Last Seen\r\n"

    rows =
      Enum.map_join(devices, "\r\n", fn d ->
        [
          csv_escape(d.mac),
          csv_escape(d.hostname || ""),
          csv_escape(if(d.arch, do: to_string(d.arch), else: "")),
          csv_escape(d.profile_id || ""),
          csv_escape(to_string(d.state)),
          csv_escape(to_string(d.install_attempts)),
          csv_escape(format_datetime(d.last_seen))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
