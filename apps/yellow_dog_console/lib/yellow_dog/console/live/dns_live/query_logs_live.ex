defmodule YellowDog.Console.DnsLive.QueryLogsLive do
  @moduledoc """
  LiveView for DNS query log viewing.

  Displays recent DNS queries with real-time streaming via PubSub,
  filtering by client IP, view, query name, type, and response code.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Dns.QueryLogger

  @max_display 200
  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, QueryLogger.pubsub_topic())
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Query Logs")
     |> assign(:search_query, "")
     |> assign(:filter_view, "all")
     |> assign(:filter_rcode, "all")
     |> assign(:filter_protocol, "all")
     |> assign(:paused, false)
     |> assign(:entries, [])
     |> assign(:stats, default_stats())
     |> load_entries()}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_entries()}
  end

  @impl true
  def handle_event("filter_view", %{"view" => view}, socket) do
    {:noreply,
     socket
     |> assign(:filter_view, view)
     |> load_entries()}
  end

  @impl true
  def handle_event("filter_rcode", %{"rcode" => rcode}, socket) do
    {:noreply,
     socket
     |> assign(:filter_rcode, rcode)
     |> load_entries()}
  end

  @impl true
  def handle_event("filter_protocol", %{"protocol" => protocol}, socket) do
    {:noreply,
     socket
     |> assign(:filter_protocol, protocol)
     |> load_entries()}
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  @impl true
  def handle_event("clear", _params, socket) do
    try do
      QueryLogger.clear_buffer()
    catch
      :exit, _ -> :ok
    end

    {:noreply, assign(socket, :entries, [])}
  end

  @impl true
  def handle_info({:query_logged, _entry}, %{assigns: %{paused: true}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:query_logged, _entry}, socket) do
    {:noreply, load_entries(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      if not socket.assigns.paused do
        socket
        |> load_entries()
        |> assign(:stats, fetch_stats())
      else
        socket
      end

    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_entries(socket) do
    entries =
      try do
        all = QueryLogger.get_recent_logs(limit: @max_display)
        filter_entries(all, socket.assigns)
      catch
        :exit, _ -> []
      end

    assign(socket, :entries, entries)
  end

  defp filter_entries(entries, assigns) do
    entries
    |> maybe_filter_search(assigns.search_query)
    |> maybe_filter_view(assigns.filter_view)
    |> maybe_filter_rcode(assigns.filter_rcode)
    |> maybe_filter_protocol(assigns.filter_protocol)
  end

  defp maybe_filter_search(entries, ""), do: entries

  defp maybe_filter_search(entries, query) do
    q = String.downcase(query)

    Enum.filter(entries, fn e ->
      (e.qname && String.contains?(String.downcase(to_string(e.qname)), q)) ||
        (e.client_ip && String.contains?(format_ip(e.client_ip), q))
    end)
  end

  defp maybe_filter_view(entries, "all"), do: entries

  defp maybe_filter_view(entries, view) do
    Enum.filter(entries, fn e -> to_string(e.view) == view end)
  end

  defp maybe_filter_rcode(entries, "all"), do: entries

  defp maybe_filter_rcode(entries, rcode) do
    Enum.filter(entries, fn e -> to_string(e.response_code) == rcode end)
  end

  defp maybe_filter_protocol(entries, "all"), do: entries

  defp maybe_filter_protocol(entries, protocol) do
    Enum.filter(entries, fn e -> to_string(e.protocol) == protocol end)
  end

  defp fetch_stats do
    try do
      QueryLogger.stats()
    catch
      :exit, _ -> default_stats()
    end
  end

  defp default_stats do
    %{buffer_size: 0, current_entries: 0, total_logged: 0, enabled: false}
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(nil), do: "-"
  defp format_ip(other), do: inspect(other)

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S") <> "." <> format_ms(dt)
  end

  defp format_timestamp(_), do: "--:--:--.---"

  defp format_ms(%DateTime{microsecond: {us, _}}) do
    ms = div(us, 1000)
    String.pad_leading(Integer.to_string(ms), 3, "0")
  end

  defp format_ms(_), do: "000"

  defp format_response_time(nil), do: "-"
  defp format_response_time(us) when us < 1_000, do: "#{us}us"
  defp format_response_time(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_response_time(us), do: "#{Float.round(us / 1_000_000, 2)}s"

  defp rcode_badge("noerror"), do: "badge-success"
  defp rcode_badge("nxdomain"), do: "badge-warning"
  defp rcode_badge("servfail"), do: "badge-error"
  defp rcode_badge("refused"), do: "badge-error"
  defp rcode_badge(_), do: "badge-ghost"

  defp protocol_badge("udp"), do: "badge-info"
  defp protocol_badge("tcp"), do: "badge-primary"
  defp protocol_badge(_), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <%!-- Header --%>
        <div class="flex flex-wrap justify-between items-center gap-4">
          <h1 class="text-2xl font-bold">DNS Query Logs</h1>
          <div class="join">
            <button
              phx-click="toggle_pause"
              class={"btn btn-sm join-item " <> if(@paused, do: "btn-warning", else: "btn-ghost")}
            >
              <%= if @paused do %>
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                Resume
              <% else %>
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 9v6m4-6v6m7-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                Pause
              <% end %>
            </button>
            <button phx-click="clear" class="btn btn-sm btn-ghost join-item">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
              </svg>
              Clear
            </button>
          </div>
        </div>

        <%!-- Stats --%>
        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Total Logged</div>
            <div class="stat-value text-lg">{@stats.total_logged}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Buffer</div>
            <div class="stat-value text-lg">{@stats.current_entries} / {@stats.buffer_size}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Displayed</div>
            <div class="stat-value text-lg">{length(@entries)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Logger</div>
            <div class="stat-value text-lg">
              <%= if @stats.enabled do %>
                <span class="text-success">Active</span>
              <% else %>
                <span class="text-error">Disabled</span>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Filters --%>
        <div class="card bg-base-200">
          <div class="card-body py-3 px-4">
            <div class="flex flex-wrap gap-4 items-center">
              <%!-- Search --%>
              <div class="form-control">
                <input
                  type="text"
                  placeholder="Search domain or IP..."
                  class="input input-sm input-bordered w-48"
                  phx-change="search"
                  phx-debounce="300"
                  name="search"
                  value={@search_query}
                />
              </div>

              <%!-- Response Code Filter --%>
              <div class="form-control">
                <select class="select select-sm select-bordered" phx-change="filter_rcode" name="rcode">
                  <option value="all" selected={@filter_rcode == "all"}>All Codes</option>
                  <option value="noerror" selected={@filter_rcode == "noerror"}>NOERROR</option>
                  <option value="nxdomain" selected={@filter_rcode == "nxdomain"}>NXDOMAIN</option>
                  <option value="servfail" selected={@filter_rcode == "servfail"}>SERVFAIL</option>
                  <option value="refused" selected={@filter_rcode == "refused"}>REFUSED</option>
                </select>
              </div>

              <%!-- Protocol Filter --%>
              <div class="form-control">
                <select class="select select-sm select-bordered" phx-change="filter_protocol" name="protocol">
                  <option value="all" selected={@filter_protocol == "all"}>All Protocols</option>
                  <option value="udp" selected={@filter_protocol == "udp"}>UDP</option>
                  <option value="tcp" selected={@filter_protocol == "tcp"}>TCP</option>
                </select>
              </div>

              <%!-- Paused indicator --%>
              <%= if @paused do %>
                <span class="badge badge-warning badge-sm">Paused</span>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Query Log Table --%>
        <div class="card bg-base-100 shadow">
          <div class="card-body p-0">
            <div class="overflow-x-auto">
              <table class="table table-zebra table-sm">
                <thead>
                  <tr>
                    <th>Time</th>
                    <th>Client</th>
                    <th>Query Name</th>
                    <th>Type</th>
                    <th>Proto</th>
                    <th>RCode</th>
                    <th>Latency</th>
                    <th>Cache</th>
                    <th>View</th>
                  </tr>
                </thead>
                <tbody>
                  <%= if Enum.empty?(@entries) do %>
                    <tr>
                      <td colspan="9" class="text-center text-base-content/50 py-8">
                        No DNS queries recorded yet
                      </td>
                    </tr>
                  <% else %>
                    <%= for entry <- @entries do %>
                      <tr class="hover">
                        <td class="font-mono text-xs whitespace-nowrap">
                          {format_timestamp(entry.timestamp)}
                        </td>
                        <td class="font-mono text-xs">
                          {format_ip(entry.client_ip)}
                        </td>
                        <td class="font-mono text-sm max-w-xs truncate" title={entry.qname}>
                          {entry.qname || "-"}
                        </td>
                        <td>
                          <span class="badge badge-ghost badge-xs">
                            {entry.qtype |> to_string() |> String.upcase()}
                          </span>
                        </td>
                        <td>
                          <span class={"badge badge-xs " <> protocol_badge(to_string(entry.protocol))}>
                            {entry.protocol |> to_string() |> String.upcase()}
                          </span>
                        </td>
                        <td>
                          <%= if entry.response_code do %>
                            <span class={"badge badge-xs " <> rcode_badge(to_string(entry.response_code))}>
                              {entry.response_code |> to_string() |> String.upcase()}
                            </span>
                          <% else %>
                            <span class="text-base-content/40">-</span>
                          <% end %>
                        </td>
                        <td class="text-xs">
                          {format_response_time(entry.response_time_us)}
                        </td>
                        <td>
                          <%= if entry.cache_hit do %>
                            <span class="badge badge-success badge-xs">HIT</span>
                          <% else %>
                            <span class="text-base-content/40 text-xs">miss</span>
                          <% end %>
                        </td>
                        <td class="text-xs">{entry.view || "-"}</td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <%!-- Footer --%>
        <div class="text-xs text-base-content/50 flex justify-between">
          <span>Showing {length(@entries)} entries</span>
          <span :if={connected?(@socket)} class="flex items-center gap-1">
            <span class="w-2 h-2 bg-success rounded-full animate-pulse"></span> Connected
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
