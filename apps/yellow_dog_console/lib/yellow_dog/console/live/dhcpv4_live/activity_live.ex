defmodule YellowDog.Console.Dhcpv4Live.ActivityLive do
  @moduledoc """
  DHCPv4 activity log page — shows DHCP message flow in real time.

  Subscribes to DHCPv4 telemetry events and displays them in a
  circular buffer with filtering by message type, client MAC, and search.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.FormatHelper, only: [format_time_ms: 1]
  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @max_entries 500
  @refresh_interval 2_000

  @type_badges %{
    "discover" => "badge-info",
    "offer" => "badge-success",
    "request" => "badge-warning",
    "ack" => "badge-success",
    "nak" => "badge-error",
    "decline" => "badge-error",
    "release" => "badge-ghost",
    "inform" => "badge-ghost"
  }

  @telemetry_events [
    [:yellow_dog, :dhcpv4, :discover_handled],
    [:yellow_dog, :dhcpv4, :lease, :requested],
    [:yellow_dog, :dhcpv4, :lease, :granted],
    [:yellow_dog, :dhcpv4, :lease, :rejected],
    [:yellow_dog, :dhcpv4, :lease, :released],
    [:yellow_dog, :dhcpv4, :lease, :declined],
    [:yellow_dog, :dhcpv4, :offer, :failed],
    [:yellow_dog, :dhcpv4, :acl, :denied],
    [:yellow_dog, :dhcpv4, :inform, :handled],
    [:yellow_dog, :dhcpv4, :pool, :exhausted],
    [:yellow_dog, :dhcpv4, :message, :rate_limited]
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        handler_id = "dhcpv4_activity_#{inspect(self())}"

        :telemetry.attach_many(
          handler_id,
          @telemetry_events,
          &__MODULE__.handle_telemetry_event/4,
          %{pid: self()}
        )

        Process.send_after(self(), :refresh_stats, @refresh_interval)
        Process.flag(:trap_exit, true)
        assign(socket, :handler_id, handler_id)
      else
        socket
      end

    {:ok,
     assign(socket,
       page_title: "DHCPv4 Activity",
       service_running: service_running?(YellowDog.Dhcpv4),
       entries: [],
       total_count: 0,
       max_entries: @max_entries,
       search_query: "",
       filter_type: "all",
       paused: false,
       stats: %{discover: 0, offer: 0, request: 0, ack: 0, nak: 0, release: 0, decline: 0}
     )}
  end

  @doc false
  def handle_telemetry_event(event, measurements, metadata, %{pid: pid}) do
    entry = build_entry_from_telemetry(event, measurements, metadata)
    send(pid, {:dhcpv4_activity, entry})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-4">
        <.service_alert :if={not @service_running} service="DHCPv4" />

        <div class="flex flex-wrap justify-between items-center gap-4">
          <h1 class="text-2xl font-bold">DHCPv4 Activity Log</h1>
          <div class="join">
            <button
              phx-click="toggle_pause"
              class={"btn btn-sm join-item " <> if(@paused, do: "btn-warning", else: "btn-ghost")}
            >
              {if @paused, do: "▶ Resume", else: "⏸ Pause"}
            </button>
            <button phx-click="clear" class="btn btn-sm btn-ghost join-item">Clear</button>
            <button
              phx-click="export_csv"
              class="btn btn-sm btn-ghost join-item"
              id="csv-export"
              phx-hook="CsvDownload"
            >
              Export CSV
            </button>
          </div>
        </div>

        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Total Events</div>
            <div class="stat-value text-lg">{@total_count}</div>
          </div>
          <div class="stat">
            <div class="stat-title">DISCOVER</div>
            <div class="stat-value text-lg text-info">{@stats.discover}</div>
          </div>
          <div class="stat">
            <div class="stat-title">REQUEST</div>
            <div class="stat-value text-lg text-warning">{@stats.request}</div>
          </div>
          <div class="stat">
            <div class="stat-title">ACK</div>
            <div class="stat-value text-lg text-success">{@stats.ack}</div>
          </div>
          <div class="stat">
            <div class="stat-title">NAK/Decline</div>
            <div class="stat-value text-lg text-error">{@stats.nak + @stats.decline}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Displayed</div>
            <div class="stat-value text-lg">
              {length(filtered_entries(@entries, @search_query, @filter_type))}
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body py-3 px-4">
            <div class="flex flex-wrap gap-4 items-center">
              <div class="form-control">
                <input
                  type="text"
                  placeholder="Search MAC, IP, or details..."
                  aria-label="Search activity log"
                  class="input input-sm input-bordered w-48"
                  phx-change="search"
                  phx-debounce="300"
                  name="search"
                  value={@search_query}
                />
              </div>
              <div class="form-control">
                <select
                  class="select select-sm select-bordered"
                  phx-change="filter_type"
                  aria-label="Filter by message type"
                  name="type"
                >
                  <option value="all" selected={@filter_type == "all"}>All Types</option>
                  <option value="discover" selected={@filter_type == "discover"}>DISCOVER</option>
                  <option value="offer" selected={@filter_type == "offer"}>OFFER</option>
                  <option value="request" selected={@filter_type == "request"}>REQUEST</option>
                  <option value="ack" selected={@filter_type == "ack"}>ACK</option>
                  <option value="nak" selected={@filter_type == "nak"}>NAK</option>
                  <option value="decline" selected={@filter_type == "decline"}>DECLINE</option>
                  <option value="release" selected={@filter_type == "release"}>RELEASE</option>
                  <option value="inform" selected={@filter_type == "inform"}>INFORM</option>
                  <option value="error" selected={@filter_type == "error"}>Errors</option>
                </select>
              </div>
              <span :if={@paused} class="badge badge-warning badge-sm">Paused</span>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow">
          <div class="card-body p-0">
            <div class="overflow-x-auto">
              <table class="table table-zebra table-sm">
                <thead>
                  <tr>
                    <th>Time</th>
                    <th>Type</th>
                    <th>Client MAC</th>
                    <th>Client IP</th>
                    <th>Details</th>
                  </tr>
                </thead>
                <tbody>
                  <% displayed = filtered_entries(@entries, @search_query, @filter_type) %>
                  <tr :if={displayed == []}>
                    <td colspan="5" class="text-center text-base-content/50 py-8">
                      No DHCPv4 activity recorded yet
                    </td>
                  </tr>
                  <tr :for={entry <- displayed} class="hover">
                    <td class="font-mono text-xs whitespace-nowrap">
                      {format_time_ms(entry.timestamp)}
                    </td>
                    <td>
                      <span class={"badge badge-xs " <> type_badge(entry.type)}>
                        {entry.type |> to_string() |> String.upcase()}
                      </span>
                    </td>
                    <td class="font-mono text-xs">{entry.client_mac || "-"}</td>
                    <td class="font-mono text-xs">{entry.client_ip || "-"}</td>
                    <td class="text-xs max-w-xs truncate" title={entry.details}>
                      {entry.details || "-"}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <div class="text-xs text-base-content/50 flex justify-between">
          <span>
            Showing {length(filtered_entries(@entries, @search_query, @filter_type))} of {@total_count} events (buffer: {@max_entries})
          </span>
          <span :if={not @paused} class="flex items-center gap-1">
            <span class="w-2 h-2 bg-success rounded-full animate-pulse"></span> Live
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :filter_type, type)}
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  @impl true
  def handle_event("clear", _params, socket) do
    {:noreply,
     assign(socket,
       entries: [],
       total_count: 0,
       stats: %{discover: 0, offer: 0, request: 0, ack: 0, nak: 0, release: 0, decline: 0}
     )}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    csv = build_csv(socket.assigns.entries)
    filename = "dhcpv4_activity_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info({:dhcpv4_activity, entry}, %{assigns: %{paused: true}} = socket) do
    # Still count even when paused
    {:noreply, update_stats(socket, entry)}
  end

  @impl true
  def handle_info({:dhcpv4_activity, entry}, socket) do
    entries = [entry | socket.assigns.entries] |> Enum.take(@max_entries)

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> update_stats(entry)}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    socket = assign(socket, :service_running, service_running?(YellowDog.Dhcpv4))
    Process.send_after(self(), :refresh_stats, @refresh_interval)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if handler_id = socket.assigns[:handler_id] do
      :telemetry.detach(handler_id)
    end

    :ok
  end

  # --- Private ---

  defp update_stats(socket, entry) do
    total = socket.assigns.total_count + 1
    stats = socket.assigns.stats

    stats =
      case entry.type do
        :discover -> %{stats | discover: stats.discover + 1}
        :offer -> %{stats | discover: stats.discover}
        :request -> %{stats | request: stats.request + 1}
        :ack -> %{stats | ack: stats.ack + 1}
        :nak -> %{stats | nak: stats.nak + 1}
        :release -> %{stats | release: stats.release + 1}
        :decline -> %{stats | decline: stats.decline + 1}
        _ -> stats
      end

    assign(socket, total_count: total, stats: stats)
  end

  def filtered_entries(entries, search, type_filter) do
    entries
    |> filter_by_type(type_filter)
    |> filter_by_search(search)
  end

  defp filter_by_type(entries, "all"), do: entries

  defp filter_by_type(entries, "error") do
    Enum.filter(entries, fn e ->
      e.type in [:nak, :decline, :pool_exhausted, :acl_denied, :rate_limited, :error]
    end)
  end

  defp filter_by_type(entries, type) do
    Enum.filter(entries, fn e -> to_string(e.type) == type end)
  end

  defp filter_by_search(entries, ""), do: entries

  defp filter_by_search(entries, query) do
    q = String.downcase(query)

    Enum.filter(entries, fn e ->
      (e.client_mac && String.contains?(String.downcase(e.client_mac), q)) ||
        (e.client_ip && String.contains?(e.client_ip, q)) ||
        (e.details && String.contains?(String.downcase(e.details), q))
    end)
  end

  defp type_badge(type), do: Map.get(@type_badges, to_string(type), "badge-ghost")

  defp build_entry_from_telemetry(event, measurements, metadata) do
    {type, details} = classify_event(event, measurements, metadata)
    client_mac = format_mac(metadata[:client_mac] || metadata[:chaddr])
    client_ip = format_client_ip(metadata[:client_ip])

    %{
      timestamp: DateTime.utc_now(),
      type: type,
      client_mac: client_mac,
      client_ip: client_ip,
      details: details,
      duration_us: measurements[:duration]
    }
  end

  defp classify_event([:yellow_dog, :dhcpv4, :discover_handled], m, _meta) do
    duration = if m[:duration], do: " (#{div(m[:duration], 1000)}ms)", else: ""
    {:discover, "DISCOVER handled#{duration}"}
  end

  defp classify_event([:yellow_dog, :dhcpv4, :lease, :requested], _m, meta) do
    type = meta[:message_type] || :request
    state = if meta[:state], do: " [#{meta[:state]}]", else: ""
    {type, "#{type |> to_string() |> String.upcase()}#{state}"}
  end

  defp classify_event([:yellow_dog, :dhcpv4, :lease, :granted], m, meta) do
    duration = if m[:duration], do: " (#{div(m[:duration], 1000)}ms)", else: ""
    state = if meta[:state], do: " [#{meta[:state]}]", else: ""
    {:ack, "ACK — lease granted#{state}#{duration}"}
  end

  defp classify_event([:yellow_dog, :dhcpv4, :lease, :rejected], _m, meta) do
    reason = meta[:reason] || "unknown"
    {:nak, "NAK — #{reason}"}
  end

  defp classify_event([:yellow_dog, :dhcpv4, :lease, :released], m, _meta) do
    duration = if m[:duration], do: " (#{div(m[:duration], 1000)}ms)", else: ""
    {:release, "RELEASE#{duration}"}
  end

  defp classify_event([:yellow_dog, :dhcpv4, :lease, :declined], _m, meta) do
    ip = meta[:declined_ip] || "?"
    {:decline, "DECLINE for #{format_client_ip(ip)}"}
  end

  defp classify_event([:yellow_dog, :dhcpv4, :offer, :failed], _m, meta) do
    reason = meta[:reason] || "unknown"
    {:error, "OFFER failed: #{reason}"}
  end

  defp classify_event([:yellow_dog, :dhcpv4, :acl, :denied], _m, meta) do
    reason = meta[:reason] || "ACL denied"
    {:acl_denied, "ACL denied: #{reason}"}
  end

  defp classify_event([:yellow_dog, :dhcpv4, :inform, :handled], m, _meta) do
    duration = if m[:duration], do: " (#{div(m[:duration], 1000)}ms)", else: ""
    {:inform, "INFORM handled#{duration}"}
  end

  defp classify_event([:yellow_dog, :dhcpv4, :pool, :exhausted], _m, meta) do
    op = meta[:operation] || "allocation"
    {:pool_exhausted, "Pool exhausted during #{op}"}
  end

  defp classify_event([:yellow_dog, :dhcpv4, :message, :rate_limited], _m, _meta) do
    {:rate_limited, "Rate limited"}
  end

  defp classify_event(event, _m, _meta) do
    {:unknown, Enum.join(event, ".")}
  end

  defp format_mac(nil), do: nil
  defp format_mac(mac) when is_binary(mac), do: mac

  defp format_mac(mac) when is_list(mac) do
    mac
    |> Enum.map_join(":", &(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))
    |> String.downcase()
  end

  defp format_mac(mac), do: inspect(mac)

  defp format_client_ip(nil), do: nil
  defp format_client_ip(ip) when is_binary(ip), do: ip
  defp format_client_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_client_ip(ip), do: inspect(ip)

  defp build_csv(entries) do
    header = "Timestamp,Type,Client MAC,Client IP,Details\r\n"

    rows =
      Enum.map_join(entries, "\r\n", fn e ->
        [
          csv_escape(format_time_ms(e.timestamp)),
          csv_escape(to_string(e.type)),
          csv_escape(e.client_mac || ""),
          csv_escape(e.client_ip || ""),
          csv_escape(e.details || "")
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
