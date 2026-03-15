defmodule YellowDog.Console.FingerprintLive.DevicesLive do
  @moduledoc """
  Device inventory page listing all observed network devices on the LAN.

  Displays passive fingerprints collected from DHCP requests, showing device
  MAC addresses, IP addresses, hostnames, device types (inferred from fingerprints),
  and assigned profiles. Supports filtering, search, and drill-down to detailed
  device profiles and fingerprint information.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.ServiceHelper, only: [safe_call: 3]

  alias YellowDog.Console.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "fingerprint:devices")
    end

    {:ok,
     socket
     |> assign(
       page_title: "Device Inventory",
       search_query: "",
       filter_type: "all",
       filter_vendor: "all"
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
            <h1 class="text-4xl font-bold">Device Inventory</h1>
            <p class="mt-2 text-on-surface-variant">
              Observed network devices identified via DHCP fingerprinting
            </p>
          </div>
          <div class="flex gap-2">
            <button
              phx-click="export_csv"
              id="export-csv"
              phx-hook="CsvDownload"
              class="btn btn-outline btn-sm"
            >
              Export CSV
            </button>
          </div>
        </div>

        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <.card>
            <div class="text-sm text-on-surface-variant">Total Devices</div>
            <div class="text-2xl font-bold text-primary">{length(@all_devices)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Identified</div>
            <div class="text-2xl font-bold text-success">{@identified_count}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Unknown</div>
            <div class="text-2xl font-bold text-warning">{@unknown_count}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Showing</div>
            <div class="text-2xl font-bold">{length(@filtered_devices)}</div>
          </.card>
        </div>

        <.card>
          <div class="flex flex-col md:flex-row gap-4">
            <div class="flex-1">
              <label class="input flex items-center gap-2">
                <.dm_mdi name="magnify" class="h-4 w-4 opacity-70" />
                <input
                  type="text"
                  class="grow"
                  placeholder="Search by MAC, hostname, IP, or vendor..."
                  value={@search_query}
                  phx-change="search"
                  phx-debounce="300"
                  name="search"
                />
              </label>
            </div>
            <select
              class="select"
              phx-change="filter_type"
              name="type"
              value={@filter_type}
            >
              <option value="all">All Types</option>
              <option :for={t <- @device_types} value={t}>{t}</option>
            </select>
          </div>
        </.card>

        <.card>
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>MAC Address</th>
                  <th>IP Address(es)</th>
                  <th>Hostname</th>
                  <th>Vendor (OUI)</th>
                  <th>Profile</th>
                  <th>Confidence</th>
                  <th>Last Seen</th>
                  <th>Count</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@filtered_devices == []}>
                  <td colspan="8" class="text-center text-on-surface-variant py-8">
                    No devices found matching your criteria
                  </td>
                </tr>
                <tr :for={device <- @filtered_devices}>
                  <td class="font-mono text-sm">
                    <.link
                      navigate={"/system/fingerprint/devices/#{device.mac}"}
                      class="link link-primary"
                    >
                      {device.mac}
                    </.link>
                  </td>
                  <td class="text-sm">
                    {format_ips(device)}
                  </td>
                  <td>{device.hostname || "-"}</td>
                  <td class="text-sm">{device.oui_vendor || "-"}</td>
                  <td>
                    <.badge :if={device.profile_id} color="info" size="sm">
                      {device.profile_id}
                    </.badge>
                    <.badge :if={!device.profile_id} color="warning" size="sm">unknown</.badge>
                  </td>
                  <td>
                    <span class={confidence_color(device.profile_confidence)}>
                      {device.profile_confidence}%
                    </span>
                  </td>
                  <td class="text-sm">{format_datetime(device.last_seen)}</td>
                  <td>{device.observation_count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> apply_filters()}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, socket |> assign(:filter_type, type) |> apply_filters()}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    csv = build_csv(socket.assigns.filtered_devices)
    filename = "devices_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info({:device_updated, _device}, socket) do
    {:noreply, load_devices(socket)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "fingerprint:devices")
    :ok
  end

  # --- Private ---

  defp load_devices(socket) do
    all = safe_call(YellowDog.Fingerprint, fn -> YellowDog.Fingerprint.list_devices() end, [])
    identified = Enum.count(all, & &1.profile_id)

    types =
      all |> Enum.map(& &1.profile_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    socket
    |> assign(:all_devices, all)
    |> assign(:identified_count, identified)
    |> assign(:unknown_count, length(all) - identified)
    |> assign(:device_types, types)
    |> apply_filters()
  end

  defp apply_filters(socket) do
    devices =
      socket.assigns.all_devices
      |> filter_by_search(socket.assigns.search_query)
      |> filter_by_type(socket.assigns.filter_type)

    assign(socket, :filtered_devices, devices)
  end

  def filter_by_search(devices, ""), do: devices

  def filter_by_search(devices, query) do
    q = String.downcase(query)

    Enum.filter(devices, fn d ->
      String.contains?(String.downcase(d.mac), q) ||
        (d.hostname && String.contains?(String.downcase(d.hostname), q)) ||
        (d.oui_vendor && String.contains?(String.downcase(d.oui_vendor), q)) ||
        Enum.any?(d.ipv4_addresses, &String.contains?(&1, q)) ||
        Enum.any?(d.ipv6_addresses, &String.contains?(&1, q))
    end)
  end

  def filter_by_type(devices, "all"), do: devices

  def filter_by_type(devices, type) do
    Enum.filter(devices, &(&1.profile_id == type))
  end

  defp format_ips(device) do
    ips = device.ipv4_addresses ++ device.ipv6_addresses
    if ips == [], do: "-", else: Enum.join(ips, ", ")
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp confidence_color(c) when c >= 80, do: "text-success font-bold"
  defp confidence_color(c) when c >= 50, do: "text-warning"
  defp confidence_color(_), do: "text-on-surface-variant"

  defp build_csv(devices) do
    header = "MAC,IPv4,IPv6,Hostname,Vendor,Profile,Confidence,First Seen,Last Seen,Count\r\n"

    rows =
      Enum.map_join(devices, "\r\n", fn d ->
        [
          csv_escape(d.mac),
          csv_escape(Enum.join(d.ipv4_addresses, "; ")),
          csv_escape(Enum.join(d.ipv6_addresses, "; ")),
          csv_escape(d.hostname || ""),
          csv_escape(d.oui_vendor || ""),
          csv_escape(d.profile_id || "unknown"),
          csv_escape(to_string(d.profile_confidence)),
          csv_escape(format_datetime(d.first_seen)),
          csv_escape(format_datetime(d.last_seen)),
          csv_escape(to_string(d.observation_count))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
