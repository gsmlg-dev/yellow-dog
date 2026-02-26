defmodule YellowDog.Console.Dhcpv6Live.ActivityLive do
  @moduledoc """
  DHCPv6 activity log page — shows DHCP message flow in real time.

  Subscribes to DHCPv6 telemetry events and displays them in a
  circular buffer with filtering by message type, client DUID, and search.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.FormatHelper, only: [format_time_ms: 1, format_ip: 1]
  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @max_entries 500
  @refresh_interval 2_000

  @type_badges %{
    "solicit" => "badge-info",
    "advertise" => "badge-success",
    "request" => "badge-warning",
    "reply" => "badge-success",
    "renew" => "badge-primary",
    "rebind" => "badge-primary",
    "release" => "badge-ghost",
    "decline" => "badge-error",
    "information_request" => "badge-ghost"
  }

  @telemetry_events [
    [:yellow_dog, :dhcpv6, :solicit, :completed],
    [:yellow_dog, :dhcpv6, :lease, :requested],
    [:yellow_dog, :dhcpv6, :lease, :granted],
    [:yellow_dog, :dhcpv6, :lease, :allocation_failed],
    [:yellow_dog, :dhcpv6, :lease, :renewed],
    [:yellow_dog, :dhcpv6, :lease, :rebind],
    [:yellow_dog, :dhcpv6, :lease, :renew_failed],
    [:yellow_dog, :dhcpv6, :lease, :rebind_failed],
    [:yellow_dog, :dhcpv6, :lease, :released],
    [:yellow_dog, :dhcpv6, :lease, :release_completed],
    [:yellow_dog, :dhcpv6, :lease, :declined],
    [:yellow_dog, :dhcpv6, :lease, :decline_completed],
    [:yellow_dog, :dhcpv6, :inform, :requested],
    [:yellow_dog, :dhcpv6, :inform, :completed],
    [:yellow_dog, :dhcpv6, :message, :rate_limited],
    [:yellow_dog, :dhcpv6, :message, :invalid]
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        handler_id = "dhcpv6_activity_#{inspect(self())}"

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
       page_title: "DHCPv6 Activity",
       service_running: service_running?(YellowDog.Dhcpv6),
       entries: [],
       total_count: 0,
       max_entries: @max_entries,
       search_query: "",
       filter_type: "all",
       paused: false,
       stats: %{solicit: 0, request: 0, reply: 0, renew: 0, release: 0, decline: 0, error: 0}
     )}
  end

  @doc false
  def handle_telemetry_event(event, measurements, metadata, %{pid: pid}) do
    entry = build_entry_from_telemetry(event, measurements, metadata)
    send(pid, {:dhcpv6_activity, entry})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-4">
        <.service_alert :if={not @service_running} service="DHCPv6" />

        <div class="flex flex-wrap justify-between items-center gap-4">
          <h1 class="text-2xl font-bold">DHCPv6 Activity Log</h1>
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
            <div class="stat-title">SOLICIT</div>
            <div class="stat-value text-lg text-info">{@stats.solicit}</div>
          </div>
          <div class="stat">
            <div class="stat-title">REQUEST</div>
            <div class="stat-value text-lg text-warning">{@stats.request}</div>
          </div>
          <div class="stat">
            <div class="stat-title">REPLY</div>
            <div class="stat-value text-lg text-success">{@stats.reply}</div>
          </div>
          <div class="stat">
            <div class="stat-title">RENEW</div>
            <div class="stat-value text-lg text-primary">{@stats.renew}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Errors</div>
            <div class="stat-value text-lg text-error">{@stats.error}</div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body py-3 px-4">
            <div class="flex flex-wrap gap-4 items-center">
              <div class="form-control">
                <input
                  type="text"
                  placeholder="Search DUID, IP, or details..."
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
                  <option value="solicit" selected={@filter_type == "solicit"}>SOLICIT</option>
                  <option value="advertise" selected={@filter_type == "advertise"}>ADVERTISE</option>
                  <option value="request" selected={@filter_type == "request"}>REQUEST</option>
                  <option value="reply" selected={@filter_type == "reply"}>REPLY</option>
                  <option value="renew" selected={@filter_type == "renew"}>RENEW</option>
                  <option value="rebind" selected={@filter_type == "rebind"}>REBIND</option>
                  <option value="release" selected={@filter_type == "release"}>RELEASE</option>
                  <option value="decline" selected={@filter_type == "decline"}>DECLINE</option>
                  <option value="inform" selected={@filter_type == "inform"}>
                    INFORMATION-REQUEST
                  </option>
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
                    <th>Client</th>
                    <th>Client IP</th>
                    <th>Details</th>
                  </tr>
                </thead>
                <tbody>
                  <% displayed = filtered_entries(@entries, @search_query, @filter_type) %>
                  <tr :if={displayed == []}>
                    <td colspan="5" class="text-center text-base-content/50 py-8">
                      No DHCPv6 activity recorded yet
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
                    <td
                      class="font-mono text-xs max-w-[120px] truncate"
                      title={entry.client_duid || "-"}
                    >
                      {entry.client_duid || "-"}
                    </td>
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
       stats: %{solicit: 0, request: 0, reply: 0, renew: 0, release: 0, decline: 0, error: 0}
     )}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    csv = build_csv(socket.assigns.entries)
    filename = "dhcpv6_activity_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info({:dhcpv6_activity, entry}, %{assigns: %{paused: true}} = socket) do
    {:noreply, update_stats(socket, entry)}
  end

  @impl true
  def handle_info({:dhcpv6_activity, entry}, socket) do
    entries = [entry | socket.assigns.entries] |> Enum.take(@max_entries)

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> update_stats(entry)}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    socket = assign(socket, :service_running, service_running?(YellowDog.Dhcpv6))
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
        :solicit ->
          %{stats | solicit: stats.solicit + 1}

        :request ->
          %{stats | request: stats.request + 1}

        :reply ->
          %{stats | reply: stats.reply + 1}

        :renew ->
          %{stats | renew: stats.renew + 1}

        :rebind ->
          %{stats | renew: stats.renew + 1}

        :release ->
          %{stats | release: stats.release + 1}

        :decline ->
          %{stats | decline: stats.decline + 1}

        t when t in [:error, :allocation_failed, :invalid, :rate_limited] ->
          %{stats | error: stats.error + 1}

        _ ->
          stats
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
      e.type in [
        :error,
        :allocation_failed,
        :invalid,
        :rate_limited,
        :renew_failed,
        :rebind_failed
      ]
    end)
  end

  defp filter_by_type(entries, type) do
    Enum.filter(entries, fn e -> to_string(e.type) == type end)
  end

  defp filter_by_search(entries, ""), do: entries

  defp filter_by_search(entries, query) do
    q = String.downcase(query)

    Enum.filter(entries, fn e ->
      (e.client_duid && String.contains?(String.downcase(e.client_duid), q)) ||
        (e.client_ip && String.contains?(e.client_ip, q)) ||
        (e.details && String.contains?(String.downcase(e.details), q))
    end)
  end

  defp type_badge(type), do: Map.get(@type_badges, to_string(type), "badge-ghost")

  defp build_entry_from_telemetry(event, measurements, metadata) do
    {type, details} = classify_event(event, measurements, metadata)
    client_duid = format_duid(metadata[:client_duid] || metadata[:duid])
    client_ip = format_ip(metadata[:client_ip])

    %{
      timestamp: DateTime.utc_now(),
      type: type,
      client_duid: client_duid,
      client_ip: client_ip,
      details: details,
      duration_us: measurements[:duration]
    }
  end

  defp classify_event([:yellow_dog, :dhcpv6, :solicit, :completed], m, meta) do
    duration = if m[:duration], do: " (#{div(m[:duration], 1000)}ms)", else: ""
    ia = if meta[:ia_count], do: " #{meta[:ia_count]} IA(s)", else: ""
    {:solicit, "SOLICIT → ADVERTISE#{ia}#{duration}"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :requested], _m, meta) do
    type = meta[:message_type] || :request
    {type, "#{type |> to_string() |> String.upcase()} received"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :granted], m, _meta) do
    duration = if m[:duration], do: " (#{div(m[:duration], 1000)}ms)", else: ""
    {:reply, "REPLY — lease granted#{duration}"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :allocation_failed], _m, meta) do
    reason = meta[:reason] || "unknown"
    {:allocation_failed, "Allocation failed: #{reason}"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :renewed], _m, _meta) do
    {:renew, "RENEW received"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :rebind], _m, _meta) do
    {:rebind, "REBIND received"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :renew_failed], _m, meta) do
    reason = meta[:reason] || "unknown"
    {:renew_failed, "Renew failed: #{reason}"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :rebind_failed], _m, meta) do
    reason = meta[:reason] || "unknown"
    {:rebind_failed, "Rebind failed: #{reason}"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :released], _m, _meta) do
    {:release, "RELEASE received"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :release_completed], m, _meta) do
    duration = if m[:duration], do: " (#{div(m[:duration], 1000)}ms)", else: ""
    {:release, "RELEASE completed#{duration}"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :declined], _m, _meta) do
    {:decline, "DECLINE received"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :lease, :decline_completed], m, meta) do
    ip = format_ip(meta[:declined_ip])
    duration = if m[:duration], do: " (#{div(m[:duration], 1000)}ms)", else: ""
    {:decline, "DECLINE completed for #{ip || "?"}#{duration}"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :inform, :requested], _m, _meta) do
    {:information_request, "INFORMATION-REQUEST received"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :inform, :completed], m, _meta) do
    duration = if m[:duration], do: " (#{div(m[:duration], 1000)}ms)", else: ""
    {:information_request, "INFORMATION-REQUEST → REPLY#{duration}"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :message, :rate_limited], _m, _meta) do
    {:rate_limited, "Rate limited"}
  end

  defp classify_event([:yellow_dog, :dhcpv6, :message, :invalid], _m, meta) do
    reason = meta[:reason] || "invalid message"
    {:invalid, "Invalid: #{reason}"}
  end

  defp classify_event(event, _m, _meta) do
    {:unknown, Enum.join(event, ".")}
  end

  defp format_duid(nil), do: nil

  defp format_duid(duid) when is_binary(duid) do
    duid
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))
    |> String.downcase()
  end

  defp format_duid(duid), do: inspect(duid)

  defp build_csv(entries) do
    header = "Timestamp,Type,Client DUID,Client IP,Details\r\n"

    rows =
      Enum.map_join(entries, "\r\n", fn e ->
        [
          csv_escape(format_time_ms(e.timestamp)),
          csv_escape(to_string(e.type)),
          csv_escape(e.client_duid || ""),
          csv_escape(e.client_ip || ""),
          csv_escape(e.details || "")
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
