defmodule YellowDog.Console.LogsLive do
  @moduledoc """
  Real-time logs viewing page.

  Subscribes to telemetry log events via PubSub and displays them in real-time
  with filtering by module/application and log level.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper

  alias YellowDog.Console.LogBroadcaster

  @max_logs 1000
  @max_pending 500

  @level_priority %{
    debug: 0,
    info: 1,
    warning: 2,
    error: 3
  }

  @available_apps [
    {:yellow_dog_dns, "DNS"},
    {:yellow_dog_dhcpv4, "DHCPv4"},
    {:yellow_dog_dhcpv6, "DHCPv6"},
    {:yellow_dog_mdns, "mDNS"},
    {:yellow_dog_console, "Console"},
    {:yellow_dog, "Core"},
    {:yellow_dog_telemetry, "Telemetry"}
  ]

  @available_levels [:debug, :info, :warning, :error]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, LogBroadcaster.topic())
    end

    {:ok,
     assign(socket,
       page_title: "Logs",
       logs: [],
       pending_logs: [],
       pending_count: 0,
       paused: false,
       min_level: :debug,
       selected_apps: MapSet.new(),
       search: "",
       expanded_log_id: nil,
       available_apps: @available_apps,
       available_levels: @available_levels,
       max_logs: @max_logs
     )}
  end

  @impl true
  def handle_info({:log_event, level, measurements, metadata}, socket) do
    app = Map.get(metadata, :app, :unknown)

    if should_display?(socket.assigns, level, app) do
      entry = build_log_entry(level, measurements, metadata)

      if socket.assigns.paused do
        # Buffer logs when paused
        pending = Enum.take([entry | socket.assigns.pending_logs], @max_pending)
        {:noreply, assign(socket, pending_logs: pending, pending_count: length(pending))}
      else
        # Add to display buffer
        logs = Enum.take([entry | socket.assigns.logs], @max_logs)
        {:noreply, assign(socket, logs: logs)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    if socket.assigns.paused do
      # Resume: flush pending logs
      logs = flush_pending(socket.assigns.pending_logs, socket.assigns.logs)
      {:noreply, assign(socket, paused: false, logs: logs, pending_logs: [], pending_count: 0)}
    else
      {:noreply, assign(socket, paused: true)}
    end
  end

  @impl true
  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, logs: [], pending_logs: [], pending_count: 0)}
  end

  @impl true
  def handle_event("toggle_app", %{"app" => app_string}, socket) do
    app = String.to_existing_atom(app_string)
    selected = socket.assigns.selected_apps

    new_selected =
      if MapSet.member?(selected, app) do
        MapSet.delete(selected, app)
      else
        MapSet.put(selected, app)
      end

    {:noreply, assign(socket, selected_apps: new_selected)}
  end

  @impl true
  def handle_event("select_all_apps", _params, socket) do
    all_apps = @available_apps |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    {:noreply, assign(socket, selected_apps: all_apps)}
  end

  @impl true
  def handle_event("select_no_apps", _params, socket) do
    {:noreply, assign(socket, selected_apps: MapSet.new())}
  end

  @impl true
  def handle_event("set_level", %{"level" => level_string}, socket) do
    level = String.to_existing_atom(level_string)
    {:noreply, assign(socket, min_level: level)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, search: search)}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    logs = filtered_logs(socket.assigns.logs, socket.assigns.search)
    csv = build_logs_csv(logs)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    filename = "logs_#{timestamp}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_event("toggle_expand", %{"id" => id_string}, socket) do
    id = String.to_integer(id_string)

    new_expanded =
      if socket.assigns.expanded_log_id == id do
        nil
      else
        id
      end

    {:noreply, assign(socket, expanded_log_id: new_expanded)}
  end

  # Private functions

  defp should_display?(%{min_level: min_level, selected_apps: selected_apps}, level, app) do
    level_ok = @level_priority[level] >= @level_priority[min_level]
    app_ok = MapSet.size(selected_apps) == 0 or MapSet.member?(selected_apps, app)
    level_ok and app_ok
  end

  defp build_log_entry(level, measurements, metadata) do
    %{
      id: System.unique_integer([:positive]),
      timestamp: Map.get(measurements, :system_time, System.system_time(:nanosecond)),
      level: level,
      app: Map.get(metadata, :app, :unknown),
      module: Map.get(metadata, :module),
      function: Map.get(metadata, :function),
      line: Map.get(metadata, :line),
      message: Map.get(metadata, :message, ""),
      metadata: Map.drop(metadata, [:app, :module, :function, :line, :message])
    }
  end

  defp flush_pending(pending, logs) do
    # Merge pending into logs, respecting max size
    merged = Enum.reverse(pending) ++ logs
    Enum.take(merged, @max_logs)
  end

  defp format_timestamp(system_time) when is_integer(system_time) do
    datetime = DateTime.from_unix!(system_time, :nanosecond)
    Calendar.strftime(datetime, "%H:%M:%S") <> "." <> format_milliseconds(system_time)
  end

  defp format_timestamp(_), do: "--:--:--.---"

  defp format_milliseconds(system_time) do
    ms = rem(div(system_time, 1_000_000), 1000)
    String.pad_leading(Integer.to_string(ms), 3, "0")
  end

  defp level_color(:debug), do: "text-base-content/60"
  defp level_color(:info), do: "text-info"
  defp level_color(:warning), do: "text-warning"
  defp level_color(:error), do: "text-error"
  defp level_color(_), do: "text-base-content"

  defp level_badge(:debug), do: "badge-ghost"
  defp level_badge(:info), do: "badge-info"
  defp level_badge(:warning), do: "badge-warning"
  defp level_badge(:error), do: "badge-error"
  defp level_badge(_), do: "badge-ghost"

  defp app_name(:yellow_dog_dns), do: "DNS"
  defp app_name(:yellow_dog_dhcpv4), do: "DHCPv4"
  defp app_name(:yellow_dog_dhcpv6), do: "DHCPv6"
  defp app_name(:yellow_dog_mdns), do: "mDNS"
  defp app_name(:yellow_dog_console), do: "Console"
  defp app_name(:yellow_dog), do: "Core"
  defp app_name(:yellow_dog_telemetry), do: "Telemetry"
  defp app_name(other), do: to_string(other)

  defp app_badge_color(:yellow_dog_dns), do: "badge-primary"
  defp app_badge_color(:yellow_dog_dhcpv4), do: "badge-secondary"
  defp app_badge_color(:yellow_dog_dhcpv6), do: "badge-accent"
  defp app_badge_color(:yellow_dog_mdns), do: "badge-success"
  defp app_badge_color(:yellow_dog_console), do: "badge-warning"
  defp app_badge_color(:yellow_dog), do: "badge-info"
  defp app_badge_color(:yellow_dog_telemetry), do: "badge-neutral"
  defp app_badge_color(_), do: "badge-ghost"

  defp is_app_selected?(selected_apps, app) do
    MapSet.size(selected_apps) == 0 or MapSet.member?(selected_apps, app)
  end

  @doc "Filters logs by search term against message text. Public for testability."
  def filtered_logs(logs, ""), do: logs

  def filtered_logs(logs, search) do
    term = String.downcase(search)

    Enum.filter(logs, fn log ->
      String.contains?(String.downcase(log.message || ""), term)
    end)
  end

  defp build_logs_csv(logs) do
    header = "Timestamp,Level,App,Module,Message\n"

    rows =
      Enum.map_join(Enum.reverse(logs), "\n", fn log ->
        [
          csv_escape(format_csv_timestamp(log.timestamp)),
          csv_escape(to_string(log.level)),
          csv_escape(app_name(log.app)),
          csv_escape(if(log.module, do: inspect(log.module), else: "")),
          csv_escape(log.message || "")
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  defp format_csv_timestamp(system_time) when is_integer(system_time) do
    datetime = DateTime.from_unix!(system_time, :nanosecond)
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S") <> "." <> format_milliseconds(system_time)
  end

  defp format_csv_timestamp(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <%!-- Header --%>
        <div class="flex flex-wrap justify-between items-center gap-4">
          <h1 class="text-2xl font-bold">Real-time Logs</h1>

          <%!-- Stream Controls --%>
          <div class="flex items-center gap-2">
            <button
              class="btn btn-sm btn-outline"
              phx-click="export_csv"
              id="export-csv"
              phx-hook="CsvDownload"
            >
              Export CSV
            </button>
            <div class="join">
              <button
                phx-click="toggle_pause"
                class={"btn btn-sm join-item " <> if(@paused, do: "btn-warning", else: "btn-ghost")}
              >
                <%= if @paused do %>
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="h-4 w-4"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"
                    />
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  Resume
                <% else %>
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="h-4 w-4"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M10 9v6m4-6v6m7-3a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  Pause
                <% end %>
              </button>
              <button phx-click="clear" class="btn btn-sm btn-ghost join-item">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-4 w-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                  />
                </svg>
                Clear
              </button>
            </div>
          </div>
        </div>

        <%!-- Search --%>
        <div class="flex gap-2">
          <input
            type="text"
            placeholder="Search log messages..."
            aria-label="Search log messages"
            value={@search}
            phx-change="search"
            phx-debounce="300"
            name="search"
            class="input input-bordered input-sm flex-1"
          />
        </div>

        <%!-- Pending Badge --%>
        <%= if @paused and @pending_count > 0 do %>
          <div class="alert alert-warning py-2">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="stroke-current shrink-0 h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
              />
            </svg>
            <span>Paused - {@pending_count} pending log(s)</span>
          </div>
        <% end %>

        <%!-- Filters --%>
        <div class="card bg-base-200">
          <div class="card-body py-3 px-4">
            <div class="flex flex-wrap gap-4 items-center">
              <%!-- Level Filter --%>
              <div class="flex items-center gap-2">
                <span class="text-sm font-medium">Level:</span>
                <div class="join">
                  <%= for level <- @available_levels do %>
                    <button
                      phx-click="set_level"
                      phx-value-level={level}
                      class={"btn btn-xs join-item " <> if(@min_level == level, do: "btn-primary", else: "btn-ghost")}
                    >
                      {level}
                    </button>
                  <% end %>
                </div>
              </div>

              <div class="divider divider-horizontal m-0"></div>

              <%!-- Module Filter --%>
              <div class="flex items-center gap-2 flex-wrap">
                <span class="text-sm font-medium">Modules:</span>
                <div class="flex gap-1 flex-wrap">
                  <%= for {app_atom, app_label} <- @available_apps do %>
                    <label class="cursor-pointer">
                      <input
                        type="checkbox"
                        class="hidden"
                        phx-click="toggle_app"
                        phx-value-app={app_atom}
                        checked={is_app_selected?(@selected_apps, app_atom)}
                      />
                      <span class={"badge badge-sm " <> if(is_app_selected?(@selected_apps, app_atom), do: app_badge_color(app_atom), else: "badge-ghost opacity-50")}>
                        {app_label}
                      </span>
                    </label>
                  <% end %>
                </div>
                <div class="join ml-2">
                  <button phx-click="select_all_apps" class="btn btn-xs btn-ghost join-item">
                    All
                  </button>
                  <button phx-click="select_no_apps" class="btn btn-xs btn-ghost join-item">
                    None
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Filter Status --%>
        <%= if MapSet.size(@selected_apps) > 0 do %>
          <div class="text-sm text-base-content/60">
            Showing: {MapSet.size(@selected_apps)} of {length(@available_apps)} modules
            | Min level: {@min_level}
          </div>
        <% end %>

        <%!-- Log Container --%>
        <div
          id="log-container"
          phx-hook="LogAutoScroll"
          class="bg-base-200 rounded-lg p-2 font-mono text-sm h-[600px] overflow-y-auto"
        >
          <%= if Enum.empty?(@logs) do %>
            <div class="flex items-center justify-center h-full text-base-content/50">
              <div class="text-center">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-12 w-12 mx-auto mb-2 opacity-50"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                  />
                </svg>
                <p>Waiting for log events...</p>
                <p class="text-xs mt-1">Logs will appear here in real-time</p>
              </div>
            </div>
          <% else %>
            <%= for log <- Enum.reverse(filtered_logs(@logs, @search)) do %>
              <div
                class={"py-1 px-2 border-b border-base-300 hover:bg-base-300/50 cursor-pointer " <> level_color(log.level)}
                phx-click="toggle_expand"
                phx-value-id={log.id}
              >
                <%!-- Log Entry Row --%>
                <div class="flex items-start gap-2">
                  <span class="text-base-content/50 shrink-0">
                    {format_timestamp(log.timestamp)}
                  </span>
                  <span class={"badge badge-xs " <> level_badge(log.level)}>
                    {log.level}
                  </span>
                  <span class={"badge badge-xs badge-outline " <> app_badge_color(log.app)}>
                    {app_name(log.app)}
                  </span>
                  <span class="break-all">{log.message}</span>
                </div>

                <%!-- Expanded Metadata --%>
                <%= if @expanded_log_id == log.id do %>
                  <div class="mt-2 ml-4 p-2 bg-base-300 rounded text-xs">
                    <div class="grid grid-cols-2 gap-x-4 gap-y-1">
                      <%= if log.module do %>
                        <div class="text-base-content/60">Module:</div>
                        <div>{inspect(log.module)}</div>
                      <% end %>
                      <%= if log.function do %>
                        <div class="text-base-content/60">Function:</div>
                        <div>{log.function}</div>
                      <% end %>
                      <%= if log.line do %>
                        <div class="text-base-content/60">Line:</div>
                        <div>{log.line}</div>
                      <% end %>
                      <%= for {key, value} <- log.metadata do %>
                        <div class="text-base-content/60">{key}:</div>
                        <div class="break-all">{inspect(value)}</div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <%!-- Stats Bar --%>
        <div class="text-xs text-base-content/50 flex justify-between">
          <span>
            Showing {length(filtered_logs(@logs, @search))} of {length(@logs)} log entries (max {@max_logs})
          </span>
          <span :if={connected?(@socket)} class="flex items-center gap-1">
            <span class="w-2 h-2 bg-success rounded-full animate-pulse"></span> Connected
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
