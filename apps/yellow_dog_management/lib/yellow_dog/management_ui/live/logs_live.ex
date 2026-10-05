defmodule YellowDog.ManagementUI.LogsLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.LogStream

  @max_logs 1000
  @max_pending 500
  @max_seen 1500
  @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
  @level_priority @levels |> Enum.with_index() |> Map.new()
  @level_strings Map.new(@levels, &{Atom.to_string(&1), &1})
  @unavailable_pages [
    {"Task Log", "Genuine job state is not available; no task history is fabricated."},
    {"DNS Query Logs", "Worker DNS query logs are not available in Management."},
    {"DHCPv4 Activity", "Worker DHCPv4 activity is not available in Management."},
    {"DHCPv6 Activity", "Worker DHCPv6 activity is not available in Management."},
    {"Netboot Log", "Worker Netboot logs are not available in Management."},
    {"Identity Audit", "Identity runtime audit logs are not available in Management."}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(YellowDog.ManagementUI.PubSub, LogStream.topic())

    logs = LogStream.snapshot() |> Enum.filter(&valid_entry?/1) |> newest(@max_logs)
    ids = Enum.map(logs, & &1.id)

    {:ok,
     assign(socket,
       page_title: "Logs",
       connected: connected?(socket),
       logs: logs,
       pending_logs: [],
       dropped_count: 0,
       paused: false,
       min_level: :debug,
       app_mode: :all,
       selected_apps: MapSet.new(),
       available_apps: logs |> Enum.map(& &1.app) |> MapSet.new(),
       search: "",
       search_form: to_form(%{"search" => ""}),
       expanded_log_id: nil,
       seen_ids: MapSet.new(ids),
       seen_order: ids,
       levels: @levels,
       unavailable_pages: @unavailable_pages
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(
       socket,
       :page_title,
       if(socket.assigns.live_action == :realtime, do: "Realtime Logs", else: "Logs")
     )}
  end

  @impl true
  def handle_info({:management_log, entry}, socket) do
    if valid_entry?(entry) and not MapSet.member?(socket.assigns.seen_ids, entry.id) do
      ids = Enum.take([entry.id | socket.assigns.seen_order], @max_seen)

      socket =
        assign(socket,
          seen_order: ids,
          seen_ids: MapSet.new(ids),
          available_apps: MapSet.put(socket.assigns.available_apps, entry.app)
        )

      if socket.assigns.paused do
        pending = [entry | socket.assigns.pending_logs]
        dropped = max(length(pending) - @max_pending, 0)

        {:noreply,
         assign(socket,
           pending_logs: newest(pending, @max_pending),
           dropped_count: socket.assigns.dropped_count + dropped
         )}
      else
        {:noreply, assign(socket, :logs, newest([entry | socket.assigns.logs], @max_logs))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    if socket.assigns.paused do
      logs = newest(socket.assigns.pending_logs ++ socket.assigns.logs, @max_logs)
      {:noreply, assign(socket, paused: false, logs: logs, pending_logs: [])}
    else
      {:noreply, assign(socket, :paused, true)}
    end
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, logs: [], pending_logs: [], dropped_count: 0, expanded_log_id: nil)}
  end

  def handle_event("toggle_app", %{"app" => app}, socket) when is_binary(app) do
    if MapSet.member?(socket.assigns.available_apps, app) do
      selected =
        if socket.assigns.app_mode == :all,
          do: socket.assigns.available_apps,
          else: socket.assigns.selected_apps

      selected =
        if MapSet.member?(selected, app),
          do: MapSet.delete(selected, app),
          else: MapSet.put(selected, app)

      {:noreply, assign(socket, app_mode: :selected, selected_apps: selected)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_all_apps", _params, socket),
    do: {:noreply, assign(socket, app_mode: :all, selected_apps: socket.assigns.available_apps)}

  def handle_event("select_no_apps", _params, socket),
    do: {:noreply, assign(socket, app_mode: :selected, selected_apps: MapSet.new())}

  def handle_event("set_level", %{"level" => level}, socket) do
    case Map.fetch(@level_strings, level) do
      {:ok, level} -> {:noreply, assign(socket, :min_level, level)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("search", %{"search" => search}, socket)
      when is_binary(search) and byte_size(search) <= 1024 do
    {:noreply, assign(socket, search: search, search_form: to_form(%{"search" => search}))}
  end

  def handle_event("toggle_expand", %{"id" => value}, socket)
      when is_binary(value) and byte_size(value) <= 20 do
    with true <- Regex.match?(~r/\A[1-9][0-9]*\z/, value),
         {id, ""} <- Integer.parse(value),
         true <- Enum.any?(socket.assigns.logs, &(&1.id == id)) do
      {:noreply,
       assign(
         socket,
         :expanded_log_id,
         if(socket.assigns.expanded_log_id == id, do: nil, else: id)
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("export_csv", _params, socket) do
    logs = visible_logs(socket.assigns)

    rows =
      Enum.map(Enum.reverse(logs), fn log ->
        [
          DateTime.to_iso8601(log.timestamp),
          Atom.to_string(log.level),
          log.app,
          log.message,
          Jason.encode!(log.metadata)
        ]
        |> Enum.map_join(",", &csv_escape/1)
      end)

    csv = "Timestamp,Level,App,Message,Metadata\r\n" <> Enum.map_join(rows, "", &(&1 <> "\r\n"))

    filename =
      "management_logs_" <> Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S") <> ".csv"

    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp valid_entry?(%{
         id: id,
         timestamp: %DateTime{},
         level: level,
         app: app,
         message: message,
         metadata: metadata
       })
       when is_integer(id) and id > 0 and level in @levels and is_binary(app) and
              is_binary(message) and is_map(metadata) do
    Enum.all?(metadata, fn {key, value} ->
      (is_binary(key) or is_atom(key)) and is_binary(value)
    end)
  end

  defp valid_entry?(_entry), do: false

  defp newest(logs, limit) do
    logs
    |> Enum.sort_by(&{DateTime.to_unix(&1.timestamp, :microsecond), &1.id}, :desc)
    |> Enum.take(limit)
  end

  defp visible_logs(assigns) do
    term = String.downcase(assigns.search)

    Enum.filter(assigns.logs, fn log ->
      @level_priority[log.level] >= @level_priority[assigns.min_level] and
        app_selected?(assigns, log.app) and String.contains?(String.downcase(log.message), term)
    end)
  end

  defp app_selected?(%{app_mode: :all}, _app), do: true
  defp app_selected?(assigns, app), do: MapSet.member?(assigns.selected_apps, app)

  defp csv_escape(value) do
    value = if Regex.match?(~r/\A(?:[\t\r\n]|\s*[=+\-@])/u, value), do: "'" <> value, else: value

    if String.contains?(value, [",", "\"", "\r", "\n"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end

  defp level_badge(level) when level in [:emergency, :alert, :critical, :error], do: "badge-error"
  defp level_badge(:warning), do: "badge-warning"
  defp level_badge(level) when level in [:notice, :info], do: "badge-info"
  defp level_badge(_level), do: "badge-ghost"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible_logs, visible_logs(assigns))

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <h1>{@page_title}</h1>
      <p class="text-on-surface-variant">
        Actual logs from this Management process. Worker logs are not ingested; service and task-log migration is not complete.
      </p>
      <div id="logs-navigation" class="management-actions">
        <.link patch="/system/logs" class="btn btn-ghost">Logs</.link><.link
          patch="/system/logs/realtime"
          class="btn btn-primary"
        >Realtime Logs</.link>
      </div>
      <div :if={@live_action == :index}>
        <.card title="Realtime Logs">
          <p>Live-streaming OTP Logger events from Management and its actual dependencies.</p><.link
            patch="/system/logs/realtime"
            class="btn btn-primary"
          >Open Realtime Logs</.link>
        </.card>
        <.card :for={{title, description} <- @unavailable_pages} title={title}>
          <p>{description}</p><span class="badge badge-ghost">Not migrated</span>
        </.card>
      </div>
      <div :if={@live_action == :realtime}>
        <div id="log-controls" class="card bg-surface-container">
          <div class="card-body">
            <div class="management-actions">
              <button
                class="btn btn-sm btn-outline"
                phx-click="export_csv"
                id="export-logs"
                phx-hook="CsvDownload"
              >Export CSV</button>
              <button
                phx-click="toggle_pause"
                class={if @paused, do: "btn btn-sm btn-warning", else: "btn btn-sm btn-ghost"}
              >{if @paused, do: "Resume", else: "Pause"}</button>
              <button phx-click="clear" class="btn btn-sm btn-ghost">Clear View</button>
            </div>
            <.form for={@search_form} id="log-search-form" phx-change="search" phx-submit="search">
              <input
                name="search"
                value={@search}
                placeholder="Search log messages..."
                aria-label="Search log messages"
                maxlength="1024"
                phx-debounce="300"
                class="input input-sm"
              />
            </.form>
            <div class="management-actions">
              <span>Level:</span><button
                :for={level <- @levels}
                phx-click="set_level"
                phx-value-level={level}
                aria-pressed={to_string(@min_level == level)}
                class={
                  if @min_level == level, do: "btn btn-xs btn-primary", else: "btn btn-xs btn-ghost"
                }
              >{level}</button>
            </div>
            <div class="management-actions">
              <span>Applications:</span>
              <label :for={app <- Enum.sort(@available_apps)}>
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  phx-click="toggle_app"
                  phx-value-app={app}
                  checked={app_selected?(assigns, app)}
                />{app}
              </label>
              <button phx-click="select_all_apps" class="btn btn-xs btn-ghost">All</button>
              <button phx-click="select_no_apps" class="btn btn-xs btn-ghost">None</button>
            </div>
          </div>
        </div>
        <div
          id="log-buffer-status"
          data-paused={to_string(@paused)}
          data-pending={length(@pending_logs)}
          data-dropped={@dropped_count}
          role="status"
          class="text-on-surface-variant"
        >
          {if @paused, do: "Paused", else: "Live"} — {length(@pending_logs)} pending log(s), max 500. Dropped while paused: {@dropped_count}. Backend replay is unchanged by Clear View.
        </div>
        <div
          id="log-container"
          phx-hook="LogAutoScroll"
          class="card bg-surface-container font-mono text-sm management-records"
        >
          <p :if={@visible_logs == []} class="text-on-surface-variant">
            No matching log events. Waiting for log events...
          </p>
          <div
            :for={log <- Enum.reverse(@visible_logs)}
            id={"log-row-#{log.id}"}
            class="border-b border-outline"
          >
            <div class="management-actions">
              <time datetime={DateTime.to_iso8601(log.timestamp)} class="text-on-surface-variant">{Calendar.strftime(
                log.timestamp,
                "%H:%M:%S.%f"
              )}</time>
              <span class={"badge badge-xs " <> level_badge(log.level)}>{log.level}</span>
              <span class="badge badge-xs badge-outline">{log.app}</span>
              <span class="break-all">{log.message}</span>
              <button
                class="btn btn-xs btn-ghost"
                phx-click="toggle_expand"
                phx-value-id={log.id}
                aria-expanded={to_string(@expanded_log_id == log.id)}
              >Metadata</button>
            </div>
            <dl
              :if={@expanded_log_id == log.id}
              id={"log-metadata-#{log.id}"}
              class="bg-surface-container-high text-xs"
            >
              <div :for={
                {key, value} <- Enum.sort_by(log.metadata, fn {key, _value} -> to_string(key) end)
              }>
                <dt class="text-on-surface-variant">{key}</dt><dd class="break-all">{value}</dd>
              </div>
            </dl>
          </div>
        </div>
        <p class="text-xs text-on-surface-variant">
          Showing {length(@visible_logs)} of {length(@logs)} log entries (max 1000). {if @connected,
            do: "Connected",
            else: "Connecting"}
        </p>
      </div>
    </Layouts.app>
    """
  end
end
