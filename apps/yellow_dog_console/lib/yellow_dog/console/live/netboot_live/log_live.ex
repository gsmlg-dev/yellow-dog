defmodule YellowDog.Console.NetbootLive.LogLive do
  @moduledoc "Netboot activity log — chronological stream of all netboot events."
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.FormatHelper, only: [format_bytes: 1]

  alias YellowDog.Console.Layouts

  @max_log_entries 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:devices")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:tftp")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:log")
    end

    {:ok,
     socket
     |> assign(
       page_title: "Boot Log",
       log_entries: [],
       search_query: "",
       filter_type: "all",
       paused: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-4xl font-bold">Boot Log</h1>
            <p class="mt-2 text-base-content/70">
              Real-time netboot activity stream
            </p>
          </div>
          <div class="flex gap-2">
            <button
              phx-click="toggle_pause"
              class={["btn btn-sm", if(@paused, do: "btn-warning", else: "btn-ghost")]}
            >
              {if @paused, do: "Resume", else: "Pause"}
            </button>
            <button phx-click="clear_log" class="btn btn-ghost btn-sm">Clear</button>
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
                  placeholder="Filter log entries..."
                  value={@search_query}
                  phx-change="search"
                  phx-debounce="300"
                  name="search"
                />
              </label>
            </div>
            <select
              class="select select-bordered"
              phx-change="filter_type"
              name="type"
              value={@filter_type}
            >
              <option value="all">All Events</option>
              <option value="device">Device Events</option>
              <option value="tftp">TFTP Events</option>
            </select>
          </div>
        </.card>

        <.card>
          <div class="overflow-x-auto max-h-[600px] overflow-y-auto">
            <table class="table table-zebra table-sm">
              <thead class="sticky top-0 bg-base-200 z-10">
                <tr>
                  <th>Time</th>
                  <th>Type</th>
                  <th>Details</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={filtered_entries(@log_entries, @search_query, @filter_type) == []}>
                  <td colspan="3" class="text-center text-base-content/50 py-8">
                    No log entries yet — activity will appear in real-time
                  </td>
                </tr>
                <tr :for={entry <- filtered_entries(@log_entries, @search_query, @filter_type)}>
                  <td class="text-sm font-mono whitespace-nowrap">{entry.time}</td>
                  <td>
                    <.badge color={type_color(entry.type)} size="sm">{entry.type}</.badge>
                  </td>
                  <td class="text-sm">{entry.message}</td>
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
    {:noreply, assign(socket, :search_query, query)}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :filter_type, type)}
  end

  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("clear_log", _params, socket) do
    {:noreply, assign(socket, :log_entries, [])}
  end

  def handle_event("export_csv", _params, socket) do
    entries =
      filtered_entries(
        socket.assigns.log_entries,
        socket.assigns.search_query,
        socket.assigns.filter_type
      )

    csv = build_csv(entries)
    filename = "boot_log_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info(msg, %{assigns: %{paused: true}} = socket) when not is_tuple(msg) do
    {:noreply, socket}
  end

  def handle_info({:device_state_changed, device}, socket) do
    entry = log_entry("device", "Device #{device.mac} → #{device.state}")
    {:noreply, add_entry(socket, entry)}
  end

  def handle_info({:device_registered, device}, socket) do
    entry = log_entry("device", "Device #{device.mac} registered")
    {:noreply, add_entry(socket, entry)}
  end

  def handle_info({:device_deleted, mac}, socket) do
    entry = log_entry("device", "Device #{mac} deleted")
    {:noreply, add_entry(socket, entry)}
  end

  def handle_info({:tftp_transfer_started, metadata}, socket) do
    file = Map.get(metadata, :file_path, "unknown")
    size = Map.get(metadata, :total_size, 0)
    entry = log_entry("tftp", "Transfer started: #{file} (#{format_bytes(size)})")
    {:noreply, add_entry(socket, entry)}
  end

  def handle_info({:tftp_transfer_complete, metadata}, socket) do
    file = Map.get(metadata, :file_path, "unknown")
    duration = Map.get(metadata, :duration, 0)
    entry = log_entry("tftp", "Transfer complete: #{file} (#{duration}ms)")
    {:noreply, add_entry(socket, entry)}
  end

  def handle_info({:tftp_request_accepted, metadata}, socket) do
    file = Map.get(metadata, :file, "unknown")
    entry = log_entry("tftp", "Request accepted: #{file}")
    {:noreply, add_entry(socket, entry)}
  end

  def handle_info({:tftp_request_rejected, metadata}, socket) do
    file = Map.get(metadata, :file, "unknown")
    reason = Map.get(metadata, :reason, "unknown")
    entry = log_entry("tftp", "Request rejected: #{file} (#{reason})")
    {:noreply, add_entry(socket, entry)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp add_entry(socket, entry) do
    if socket.assigns.paused do
      socket
    else
      entries = [entry | socket.assigns.log_entries] |> Enum.take(@max_log_entries)
      assign(socket, :log_entries, entries)
    end
  end

  defp log_entry(type, message) do
    %{
      time: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S"),
      type: type,
      message: message
    }
  end

  def filtered_entries(entries, search, type_filter) do
    entries
    |> filter_by_type(type_filter)
    |> filter_by_search(search)
  end

  def filter_by_search(entries, ""), do: entries

  def filter_by_search(entries, query) do
    q = String.downcase(query)
    Enum.filter(entries, &String.contains?(String.downcase(&1.message), q))
  end

  def filter_by_type(entries, "all"), do: entries
  def filter_by_type(entries, type), do: Enum.filter(entries, &(&1.type == type))

  defp type_color("device"), do: "info"
  defp type_color("tftp"), do: "warning"
  defp type_color(_), do: "neutral"

  defp build_csv(entries) do
    header = "Time,Type,Message\r\n"

    rows =
      Enum.map_join(entries, "\r\n", fn e ->
        [csv_escape(e.time), csv_escape(e.type), csv_escape(e.message)]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
