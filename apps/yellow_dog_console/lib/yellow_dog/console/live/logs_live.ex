defmodule YellowDog.Console.LogsLive do
  @moduledoc """
  Real-time logs viewing page.

  Subscribes to telemetry log events via PubSub and displays them in real-time
  with filtering by module/application and log level.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.FormatHelper, only: [format_time_ms: 1]
  import YellowDog.Console.StringHelper, only: [downcase_contains?: 2]

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

  @level_colors %{
    debug: "text-on-surface-variant",
    info: "text-info",
    warning: "text-warning",
    error: "text-error"
  }

  @level_badges %{
    debug: "badge-ghost",
    info: "badge-info",
    warning: "badge-warning",
    error: "badge-error"
  }

  @app_names %{
    yellow_dog_dns: "DNS",
    yellow_dog_dhcpv4: "DHCPv4",
    yellow_dog_dhcpv6: "DHCPv6",
    yellow_dog_mdns: "mDNS",
    yellow_dog_console: "Console",
    yellow_dog: "Core",
    yellow_dog_telemetry: "Telemetry"
  }

  @app_badge_colors %{
    yellow_dog_dns: "badge-primary",
    yellow_dog_dhcpv4: "badge-secondary",
    yellow_dog_dhcpv6: "badge-accent",
    yellow_dog_mdns: "badge-success",
    yellow_dog_console: "badge-warning",
    yellow_dog: "badge-info",
    yellow_dog_telemetry: "badge-neutral"
  }

  @log_pages [
    %{
      path: "/system/logs/realtime",
      title: "Realtime Logs",
      description: "Live-streaming system logs from all applications",
      icon: "pulse",
      color: "text-success"
    },
    %{
      path: "/system/logs/dns-query",
      title: "DNS Query Logs",
      description: "DNS query and response log entries",
      icon: "web",
      color: "text-primary"
    },
    %{
      path: "/system/logs/dhcpv4-activity",
      title: "DHCPv4 Activity",
      description: "DHCPv4 DORA handshake and lease activity",
      icon: "server-network",
      color: "text-secondary"
    },
    %{
      path: "/system/logs/dhcpv6-activity",
      title: "DHCPv6 Activity",
      description: "DHCPv6 lease and prefix delegation activity",
      icon: "server-network",
      color: "text-info"
    },
    %{
      path: "/system/logs/netboot",
      title: "Netboot Log",
      description: "PXE/iPXE boot events and TFTP transfers",
      icon: "flash",
      color: "text-warning"
    },
    %{
      path: "/system/logs/identity-audit",
      title: "Identity Audit",
      description: "Host registration, approval, and trust events",
      icon: "key-variant",
      color: "text-error"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Logs",
       live_action: nil,
       connected: false,
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
       max_logs: @max_logs,
       log_pages: @log_pages
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    case socket.assigns.live_action do
      :realtime ->
        if connected?(socket) and not subscribed?(socket) do
          Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, LogBroadcaster.topic())
        end

        {:noreply, assign(socket, page_title: "Realtime Logs", connected: connected?(socket))}

      _ ->
        {:noreply, assign(socket, page_title: "Logs")}
    end
  end

  defp subscribed?(socket), do: socket.assigns[:connected] == true

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
  def handle_info(_msg, socket), do: {:noreply, socket}

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

  @valid_apps ~w(yellow_dog_dns yellow_dog_dhcpv4 yellow_dog_dhcpv6 yellow_dog_mdns yellow_dog_console yellow_dog yellow_dog_telemetry)

  @impl true
  def handle_event("toggle_app", %{"app" => app_string}, socket)
      when app_string in @valid_apps do
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
  def handle_event("toggle_app", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_all_apps", _params, socket) do
    all_apps = MapSet.new(@available_apps, &elem(&1, 0))
    {:noreply, assign(socket, selected_apps: all_apps)}
  end

  @impl true
  def handle_event("select_no_apps", _params, socket) do
    {:noreply, assign(socket, selected_apps: MapSet.new())}
  end

  @valid_levels ~w(debug info warning error)

  @impl true
  def handle_event("set_level", %{"level" => level_string}, socket)
      when level_string in @valid_levels do
    level = String.to_existing_atom(level_string)
    {:noreply, assign(socket, min_level: level)}
  end

  @impl true
  def handle_event("set_level", _params, socket) do
    {:noreply, socket}
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
    case Integer.parse(id_string) do
      {id, ""} ->
        new_expanded =
          if socket.assigns.expanded_log_id == id do
            nil
          else
            id
          end

        {:noreply, assign(socket, expanded_log_id: new_expanded)}

      _ ->
        {:noreply, socket}
    end
  end

  # Private functions

  defp should_display?(%{min_level: min_level, selected_apps: selected_apps}, level, app) do
    level_ok = @level_priority[level] >= @level_priority[min_level]
    app_ok = Enum.empty?(selected_apps) or MapSet.member?(selected_apps, app)
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

  defp level_color(level), do: Map.get(@level_colors, level, "text-on-surface")

  defp level_badge(level), do: Map.get(@level_badges, level, "badge-ghost")

  defp app_name(app), do: Map.get(@app_names, app) || to_string(app)

  defp app_badge_color(app), do: Map.get(@app_badge_colors, app, "badge-ghost")

  defp is_app_selected?(selected_apps, app) do
    Enum.empty?(selected_apps) or MapSet.member?(selected_apps, app)
  end

  @doc "Filters logs by search term against message text. Public for testability."
  def filtered_logs(logs, ""), do: logs

  def filtered_logs(logs, search) do
    term = String.downcase(search)

    Enum.filter(logs, fn log ->
      downcase_contains?(log.message, term)
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
    ms = rem(div(system_time, 1_000_000), 1000)

    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S") <>
      "." <> String.pad_leading(Integer.to_string(ms), 3, "0")
  end

  defp format_csv_timestamp(_), do: ""

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div>
          <h1 class="text-4xl font-bold">Logs</h1>
          <p class="mt-2 text-on-surface-variant">
            View logs and activity across all services
          </p>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          <.link :for={page <- @log_pages} navigate={page.path} class="group">
            <.card>
              <div class="flex items-start gap-3">
                <.dm_mdi name={page.icon} class={"w-8 h-8 #{page.color}"} />
                <div>
                  <div class="font-semibold group-hover:text-primary">{page.title}</div>
                  <div class="text-sm text-on-surface-variant mt-1">{page.description}</div>
                </div>
              </div>
            </.card>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-4">
        <%!-- Header --%>
        <div class="flex flex-wrap justify-between items-center gap-4">
          <h1 class="text-2xl font-bold">Realtime Logs</h1>

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
            <div class="flex">
              <button
                phx-click="toggle_pause"
                class={"btn btn-sm " <> if(@paused, do: "btn-warning", else: "btn-ghost")}
              >
                <%= if @paused do %>
                  <.dm_mdi name="play-circle-outline" class="h-4 w-4" /> Resume
                <% else %>
                  <.dm_mdi name="pause-circle-outline" class="h-4 w-4" /> Pause
                <% end %>
              </button>
              <button phx-click="clear" class="btn btn-sm btn-ghost">
                <.dm_mdi name="delete" class="h-4 w-4" /> Clear
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
            class="input input-sm flex-1"
          />
        </div>

        <%!-- Pending Badge --%>
        <%= if @paused and @pending_count > 0 do %>
          <div class="alert alert-warning py-2">
            <.dm_mdi name="alert" class="stroke-current shrink-0 h-5 w-5" />
            <span>Paused - {@pending_count} pending log(s)</span>
          </div>
        <% end %>

        <%!-- Filters --%>
        <div class="card bg-surface-container">
          <div class="card-body py-3 px-4">
            <div class="flex flex-wrap gap-4 items-center">
              <%!-- Level Filter --%>
              <div class="flex items-center gap-2">
                <span class="text-sm font-medium">Level:</span>
                <div class="flex">
                  <%= for level <- @available_levels do %>
                    <button
                      phx-click="set_level"
                      phx-value-level={level}
                      class={"btn btn-xs " <> if(@min_level == level, do: "btn-primary", else: "btn-ghost")}
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
                <div class="flex ml-2">
                  <button phx-click="select_all_apps" class="btn btn-xs btn-ghost">
                    All
                  </button>
                  <button phx-click="select_no_apps" class="btn btn-xs btn-ghost">
                    None
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Filter Status --%>
        <%= unless Enum.empty?(@selected_apps) do %>
          <div class="text-sm text-on-surface-variant">
            Showing: {MapSet.size(@selected_apps)} of {length(@available_apps)} modules
            | Min level: {@min_level}
          </div>
        <% end %>

        <%!-- Log Container --%>
        <div
          id="log-container"
          phx-hook="LogAutoScroll"
          class="bg-surface-container rounded-lg p-2 font-mono text-sm h-[600px] overflow-y-auto"
        >
          <%= if Enum.empty?(@logs) do %>
            <div class="flex items-center justify-center h-full text-on-surface-variant">
              <div class="text-center">
                <.dm_mdi name="file-document-outline" class="h-12 w-12 mx-auto mb-2 opacity-50" />
                <p>Waiting for log events...</p>
                <p class="text-xs mt-1">Logs will appear here in real-time</p>
              </div>
            </div>
          <% else %>
            <%= for log <- Enum.reverse(filtered_logs(@logs, @search)) do %>
              <div
                class={"py-1 px-2 border-b border-outline hover:bg-surface-container-high/50 cursor-pointer " <> level_color(log.level)}
                phx-click="toggle_expand"
                phx-value-id={log.id}
              >
                <%!-- Log Entry Row --%>
                <div class="flex items-start gap-2">
                  <span class="text-on-surface-variant shrink-0">
                    {format_time_ms(log.timestamp)}
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
                  <div class="mt-2 ml-4 p-2 bg-surface-container-high rounded text-xs">
                    <div class="grid grid-cols-2 gap-x-4 gap-y-1">
                      <%= if log.module do %>
                        <div class="text-on-surface-variant">Module:</div>
                        <div>{inspect(log.module)}</div>
                      <% end %>
                      <%= if log.function do %>
                        <div class="text-on-surface-variant">Function:</div>
                        <div>{log.function}</div>
                      <% end %>
                      <%= if log.line do %>
                        <div class="text-on-surface-variant">Line:</div>
                        <div>{log.line}</div>
                      <% end %>
                      <%= for {key, value} <- log.metadata do %>
                        <div class="text-on-surface-variant">{key}:</div>
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
        <div class="text-xs text-on-surface-variant flex justify-between">
          <span>
            Showing {length(filtered_logs(@logs, @search))} of {length(@logs)} log entries (max {@max_logs})
          </span>
          <span :if={@connected} class="flex items-center gap-1">
            <span class="w-2 h-2 bg-success rounded-full animate-pulse"></span> Connected
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
