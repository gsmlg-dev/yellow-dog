defmodule YellowDog.Console.DhcpClientLive.ActivityLive do
  @moduledoc """
  DHCP Client activity log — shows state transitions, packet flow,
  and OS integration events in real time.

  Subscribes to all DHCP client telemetry events and displays them
  in a circular buffer with filtering by event type and search.
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.FormatHelper, only: [format_time_ms: 1]

  @max_entries 500

  @type_badges %{
    "state" => "badge-info",
    "discover" => "badge-info",
    "request" => "badge-warning",
    "offer" => "badge-success",
    "ack" => "badge-success",
    "nak" => "badge-error",
    "decline" => "badge-error",
    "release" => "badge-ghost",
    "bound" => "badge-success",
    "renewed" => "badge-success",
    "expired" => "badge-error",
    "os" => "badge-accent",
    "dad" => "badge-secondary",
    "config" => "badge-neutral"
  }

  @telemetry_events [
    [:yellow_dog, :dhcp_client, :state, :change],
    [:yellow_dog, :dhcp_client, :packet, :tx],
    [:yellow_dog, :dhcp_client, :packet, :rx],
    [:yellow_dog, :dhcp_client, :lease, :bound],
    [:yellow_dog, :dhcp_client, :lease, :renewed],
    [:yellow_dog, :dhcp_client, :lease, :expired],
    [:yellow_dog, :dhcp_client, :os, :apply],
    [:yellow_dog, :dhcp_client, :dad, :start],
    [:yellow_dog, :dhcp_client, :dad, :result]
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        handler_id = "dhcp_client_activity_#{inspect(self())}"

        :telemetry.attach_many(
          handler_id,
          @telemetry_events,
          &__MODULE__.handle_telemetry_event/4,
          %{pid: self()}
        )

        Process.flag(:trap_exit, true)
        assign(socket, :handler_id, handler_id)
      else
        socket
      end

    {:ok,
     assign(socket,
       page_title: "DHCP Client Activity",
       entries: [],
       total_count: 0,
       max_entries: @max_entries,
       search_query: "",
       filter_type: "all",
       paused: false,
       stats: %{
         state: 0,
         tx: 0,
         rx: 0,
         bound: 0,
         renewed: 0,
         expired: 0,
         os: 0,
         dad: 0
       }
     )}
  end

  @doc false
  def handle_telemetry_event(event, measurements, metadata, %{pid: pid}) do
    entry = build_entry(event, measurements, metadata)
    send(pid, {:dhcp_client_activity, entry})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
    <div class="space-y-4">
      <div class="flex flex-wrap justify-between items-center gap-4">
        <h1 class="text-2xl font-bold">DHCP Client Activity</h1>
        <div class="flex">
          <button
            phx-click="toggle_pause"
            class={"btn btn-sm " <> if(@paused, do: "btn-warning", else: "btn-ghost")}
          >
            {if @paused, do: "Resume", else: "Pause"}
          </button>
          <button phx-click="clear" class="btn btn-sm btn-ghost">Clear</button>
          <button
            phx-click="export_csv"
            class="btn btn-sm btn-ghost"
            id="csv-export"
            phx-hook="CsvDownload"
          >
            Export CSV
          </button>
        </div>
      </div>

      <div class="grid grid-cols-3 sm:grid-cols-6 gap-4">
        <.card>
          <div class="text-sm text-on-surface-variant">Total</div>
          <div class="text-lg font-bold">{@total_count}</div>
        </.card>
        <.card>
          <div class="text-sm text-on-surface-variant">State Changes</div>
          <div class="text-lg font-bold text-info">{@stats.state}</div>
        </.card>
        <.card>
          <div class="text-sm text-on-surface-variant">TX</div>
          <div class="text-lg font-bold text-warning">{@stats.tx}</div>
        </.card>
        <.card>
          <div class="text-sm text-on-surface-variant">RX</div>
          <div class="text-lg font-bold text-success">{@stats.rx}</div>
        </.card>
        <.card>
          <div class="text-sm text-on-surface-variant">Bound/Renewed</div>
          <div class="text-lg font-bold text-success">{@stats.bound + @stats.renewed}</div>
        </.card>
        <.card>
          <div class="text-sm text-on-surface-variant">Expired</div>
          <div class="text-lg font-bold text-error">{@stats.expired}</div>
        </.card>
      </div>

      <div class="card bg-surface-container">
        <div class="card-body py-3 px-4">
          <div class="flex flex-wrap gap-4 items-center">
            <div class="form-group">
              <input
                type="text"
                placeholder="Search interface, IP, or details..."
                aria-label="Search activity log"
                class="input input-sm w-48"
                phx-change="search"
                phx-debounce="300"
                name="search"
                value={@search_query}
              />
            </div>
            <div class="form-group">
              <select
                class="select select-sm"
                phx-change="filter_type"
                aria-label="Filter by event type"
                name="type"
              >
                <option value="all" selected={@filter_type == "all"}>All Events</option>
                <option value="state" selected={@filter_type == "state"}>State Changes</option>
                <option value="tx" selected={@filter_type == "tx"}>Packet TX</option>
                <option value="rx" selected={@filter_type == "rx"}>Packet RX</option>
                <option value="lease" selected={@filter_type == "lease"}>Lease Events</option>
                <option value="os" selected={@filter_type == "os"}>OS Integration</option>
                <option value="dad" selected={@filter_type == "dad"}>DAD</option>
              </select>
            </div>
            <span :if={@paused} class="badge badge-warning badge-sm">Paused</span>
          </div>
        </div>
      </div>

      <div class="card bg-surface shadow">
        <div class="card-body p-0">
          <div class="overflow-x-auto">
            <table class="table table-striped table-sm">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Type</th>
                  <th>Interface</th>
                  <th>Details</th>
                </tr>
              </thead>
              <tbody>
                <% displayed = filtered_entries(@entries, @search_query, @filter_type) %>
                <tr :if={displayed == []}>
                  <td colspan="4" class="text-center text-on-surface-variant py-8">
                    No DHCP client activity recorded yet
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
                  <td class="font-mono text-xs">{entry.interface || "-"}</td>
                  <td class="text-xs max-w-md truncate" title={entry.details}>
                    {entry.details || "-"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="text-xs text-on-surface-variant flex justify-between">
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

  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :filter_type, type)}
  end

  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     assign(socket,
       entries: [],
       total_count: 0,
       stats: %{state: 0, tx: 0, rx: 0, bound: 0, renewed: 0, expired: 0, os: 0, dad: 0}
     )}
  end

  def handle_event("export_csv", _params, socket) do
    csv = build_csv(socket.assigns.entries)

    filename =
      "dhcp_client_activity_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"

    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info({:dhcp_client_activity, entry}, %{assigns: %{paused: true}} = socket) do
    {:noreply, update_stats(socket, entry)}
  end

  def handle_info({:dhcp_client_activity, entry}, socket) do
    entries = [entry | socket.assigns.entries] |> Enum.take(@max_entries)

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> update_stats(entry)}
  end

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
      case entry.category do
        :state -> %{stats | state: stats.state + 1}
        :tx -> %{stats | tx: stats.tx + 1}
        :rx -> %{stats | rx: stats.rx + 1}
        :bound -> %{stats | bound: stats.bound + 1}
        :renewed -> %{stats | renewed: stats.renewed + 1}
        :expired -> %{stats | expired: stats.expired + 1}
        :os -> %{stats | os: stats.os + 1}
        :dad -> %{stats | dad: stats.dad + 1}
        _ -> stats
      end

    assign(socket, total_count: total, stats: stats)
  end

  defp filtered_entries(entries, search, type_filter) do
    entries
    |> filter_by_type(type_filter)
    |> filter_by_search(search)
  end

  defp filter_by_type(entries, "all"), do: entries

  defp filter_by_type(entries, "lease") do
    Enum.filter(entries, fn e -> e.category in [:bound, :renewed, :expired] end)
  end

  defp filter_by_type(entries, type) do
    type_atom = String.to_existing_atom(type)
    Enum.filter(entries, fn e -> e.category == type_atom end)
  rescue
    ArgumentError -> entries
  end

  defp filter_by_search(entries, ""), do: entries

  defp filter_by_search(entries, query) do
    q = String.downcase(query)

    Enum.filter(entries, fn e ->
      (e.interface && String.contains?(String.downcase(e.interface), q)) ||
        (e.details && String.contains?(String.downcase(e.details), q))
    end)
  end

  defp type_badge(type), do: Map.get(@type_badges, to_string(type), "badge-ghost")

  defp build_entry(event, measurements, metadata) do
    {type, category, details} = classify_event(event, measurements, metadata)
    interface = metadata[:interface] || "unknown"

    %{
      timestamp: DateTime.utc_now(),
      type: type,
      category: category,
      interface: interface,
      details: details
    }
  end

  defp classify_event([:yellow_dog, :dhcp_client, :state, :change], m, meta) do
    from = meta[:from] || "?"
    to = meta[:to] || "?"
    duration = m[:duration_in_state_ms]
    dur_str = if duration && duration > 0, do: " (#{duration}ms in #{from})", else: ""
    {:state, :state, "#{from} -> #{to}#{dur_str}"}
  end

  defp classify_event([:yellow_dog, :dhcp_client, :packet, :tx], _m, meta) do
    pkt_type = meta[:type] || :unknown
    {pkt_type, :tx, "TX #{pkt_type |> to_string() |> String.upcase()}"}
  end

  defp classify_event([:yellow_dog, :dhcp_client, :packet, :rx], _m, meta) do
    pkt_type = meta[:type] || :unknown
    server = meta[:server] || "unknown"
    {pkt_type, :rx, "RX #{pkt_type |> to_string() |> String.upcase()} from #{server}"}
  end

  defp classify_event([:yellow_dog, :dhcp_client, :lease, :bound], m, meta) do
    ip = meta[:ip] || "?"
    server = meta[:server] || "?"
    lease_time = m[:lease_time_s] || "?"
    handshake = m[:handshake_duration_ms]
    hs_str = if handshake, do: " handshake=#{handshake}ms", else: ""
    {:bound, :bound, "BOUND #{ip} from #{server} (#{lease_time}s#{hs_str})"}
  end

  defp classify_event([:yellow_dog, :dhcp_client, :lease, :renewed], m, meta) do
    ip = meta[:ip] || "?"
    lease_time = m[:lease_time_s] || "?"
    {:renewed, :renewed, "RENEWED #{ip} (#{lease_time}s)"}
  end

  defp classify_event([:yellow_dog, :dhcp_client, :lease, :expired], _m, meta) do
    ip = meta[:ip] || "?"
    {:expired, :expired, "EXPIRED #{ip}"}
  end

  defp classify_event([:yellow_dog, :dhcp_client, :os, :apply], m, meta) do
    action = meta[:action] || :unknown
    result = meta[:result] || :unknown
    duration = m[:duration_ms]
    dur_str = if duration, do: " (#{duration}ms)", else: ""
    {:os, :os, "OS #{action} #{result}#{dur_str}"}
  end

  defp classify_event([:yellow_dog, :dhcp_client, :dad, :start], _m, meta) do
    ip = meta[:ip] || "?"
    {:dad, :dad, "DAD start for #{ip}"}
  end

  defp classify_event([:yellow_dog, :dhcp_client, :dad, :result], _m, meta) do
    ip = meta[:ip] || "?"
    conflict = meta[:conflict]
    result = if conflict, do: "CONFLICT", else: "OK"
    {:dad, :dad, "DAD #{result} for #{ip}"}
  end

  defp classify_event(event, _m, _meta) do
    {:unknown, :unknown, Enum.join(event, ".")}
  end

  defp build_csv(entries) do
    header = "Timestamp,Type,Category,Interface,Details\r\n"

    rows =
      Enum.map_join(entries, "\r\n", fn e ->
        [
          csv_escape(format_time_ms(e.timestamp)),
          csv_escape(to_string(e.type)),
          csv_escape(to_string(e.category)),
          csv_escape(e.interface || ""),
          csv_escape(e.details || "")
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
