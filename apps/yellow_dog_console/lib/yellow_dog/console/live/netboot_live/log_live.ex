defmodule YellowDog.Console.NetbootLive.LogLive do
  @moduledoc "Management-backed Netboot event log for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.NetbootLive.ManagementComponents
  alias YellowDog.Console.NetbootLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Netboot Log",
       subscribed_server_id: nil,
       entries: [],
       search_query: "",
       type_filter: "all",
       level_filter: "all",
       paused?: false,
       management_error: nil,
       cached_snapshot?: false,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_logs(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket),
    do: {:noreply, assign(socket, :search_query, query)}

  def handle_event("filter_type", params, socket),
    do: {:noreply, assign(socket, :type_filter, params["type"] || "all")}

  def handle_event("filter_level", params, socket),
    do: {:noreply, assign(socket, :level_filter, params["level"] || "all")}

  def handle_event("toggle_pause", _params, socket),
    do: {:noreply, update(socket, :paused?, &(!&1))}

  def handle_event("clear_log", _params, socket) do
    {:noreply,
     ManagementSupport.unavailable(
       socket,
       "Clearing the log is unavailable through Server management"
     )}
  end

  def handle_event("export_csv", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_logs(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="server-netboot-log" class="space-y-6">
        <div class="flex items-center justify-between gap-4">
          <ManagementComponents.page_header
            title="Netboot Log"
            subtitle="Events reported by the selected Server"
            server={@selected_server}
            online?={@service_online?}
            back={ServicePaths.server_path(@selected_server.id, :netboot)}
          />
          <div class="flex gap-2">
            <button phx-click="toggle_pause" class="btn btn-outline btn-sm">{if @paused?,
              do: "Resume",
              else: "Pause"}</button>
            <button phx-click="clear_log" disabled class="btn btn-outline btn-sm">Clear unavailable</button>
            <button id="export-csv" phx-click="export_csv" class="btn btn-outline btn-sm">Export CSV</button>
          </div>
        </div>

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />
        <div :if={@paused?} class="alert alert-info">Log display paused</div>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.card>
            <div class="text-sm text-on-surface-variant">Entries</div><div class="text-2xl font-bold">
              {length(@entries)}
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Devices</div><div class="text-2xl font-bold">
              {@entries |> Enum.map(& &1["device_id"]) |> Enum.uniq() |> length()}
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Source</div><div class="text-lg font-bold">
              Management
            </div>
          </.card>
        </div>

        <.card>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <label class="input flex items-center gap-2"><.dm_mdi
              name="magnify"
              class="h-4 w-4 opacity-70"
            /><input name="search" value={@search_query} phx-change="search" placeholder="Search log" /></label>
            <select name="type" phx-change="filter_type" class="select select-bordered"><option value="all">
              All event types
            </option></select>
            <select name="level" phx-change="filter_level" class="select select-bordered"><option value="all">
              All levels
            </option><option value="info">Info</option><option value="warning">Warning</option><option value="error">
              Error
            </option></select>
          </div>
        </.card>

        <.card>
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>Time</th><th>Log ID</th><th>Device</th><th>Level</th><th>Message</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={displayed_entries(assigns) == []}>
                  <td colspan="5" class="py-8 text-center text-on-surface-variant">
                    No Netboot log entries in this Server snapshot
                  </td>
                </tr>
                <tr :for={entry <- displayed_entries(assigns)}>
                  <td>{entry_value(entry, "occurred_at")}</td><td>{entry_value(entry, "log_id")}</td><td>
                    {entry_value(entry, "device_id")}
                  </td><td>
                    <.badge color="info" size="sm">{entry_value(entry, "level", "info")}</.badge>
                  </td><td>{entry_value(entry, "message")}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  def filtered_entries(entries, query, type_filter, level_filter) do
    entries
    |> filter_by_search(query)
    |> filter_by_type(type_filter)
    |> filter_by_level(level_filter)
  end

  def filter_by_level(entries, "all"), do: entries
  def filter_by_level(entries, "info"), do: entries

  def filter_by_level(entries, "warning") do
    Enum.filter(entries, &(entry_value(&1, "level", "info") in ["warning", "error"]))
  end

  def filter_by_level(entries, level),
    do: Enum.filter(entries, &(entry_value(&1, "level", "info") == level))

  defp load_logs(socket, server_id) do
    result = ServerManagement.netboot_logs_list(server_id)
    results = [result]

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — Netboot Log",
      entries: ManagementSupport.items(result),
      management_error: if(ManagementSupport.error_result?(result), do: result),
      cached_snapshot?: ManagementSupport.cached?(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at)
    )
  end

  defp displayed_entries(assigns) do
    if assigns.paused? do
      []
    else
      filtered_entries(
        assigns.entries,
        assigns.search_query,
        assigns.type_filter,
        assigns.level_filter
      )
    end
  end

  defp filter_by_search(entries, ""), do: entries

  defp filter_by_search(entries, query) do
    query = String.downcase(query)

    Enum.filter(entries, fn entry ->
      Enum.any?(~w(log_id device_id message), fn key ->
        entry |> entry_value(key) |> String.downcase() |> String.contains?(query)
      end)
    end)
  end

  defp filter_by_type(entries, "all"), do: entries
  defp filter_by_type(entries, type), do: Enum.filter(entries, &(entry_value(&1, "type") == type))

  defp entry_value(entry, key, default \\ "") do
    atom_key = known_atom_key(key)

    value =
      Map.get(entry, key, if(atom_key, do: Map.get(entry, atom_key, default), else: default))

    to_string(value || default)
  end

  defp known_atom_key("log_id"), do: :log_id
  defp known_atom_key("device_id"), do: :device_id
  defp known_atom_key("message"), do: :message
  defp known_atom_key("occurred_at"), do: :occurred_at
  defp known_atom_key("level"), do: :level
  defp known_atom_key("type"), do: :type
  defp known_atom_key(_key), do: nil
end
