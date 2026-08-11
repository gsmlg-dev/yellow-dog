defmodule YellowDog.Console.NetbootLive.TftpLive do
  @moduledoc "Management-backed Netboot assets and transfers for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.NetbootLive.ManagementComponents
  alias YellowDog.Console.NetbootLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @unavailable_message "Asset mutation is unavailable because Management does not expose an exact owner revision"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Netboot Assets",
       subscribed_server_id: nil,
       assets: [],
       transfers: [],
       transfer_filter: "",
       transfer_sort_field: "transfer_id",
       transfer_sort_dir: "asc",
       management_error: nil,
       cached_snapshot?: false,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_assets(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event(event, _params, socket)
      when event in ["upload_asset", "save_upload", "rescan", "delete_asset", "delete_file"] do
    {:noreply, ManagementSupport.unavailable(socket, @unavailable_message)}
  end

  def handle_event("filter_history", params, socket) do
    {:noreply, assign(socket, :transfer_filter, params["filter"] || "")}
  end

  def handle_event("sort_history", %{"field" => field}, socket) do
    dir =
      if socket.assigns.transfer_sort_field == field,
        do: toggle_dir(socket.assigns.transfer_sort_dir),
        else: "asc"

    {:noreply, assign(socket, transfer_sort_field: field, transfer_sort_dir: dir)}
  end

  def handle_event(event, _params, socket)
      when event in ["export_history_csv", "export_files_csv", "validate_upload", "cancel_upload"],
      do: {:noreply, socket}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_assets(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="server-netboot-assets" class="space-y-6">
        <ManagementComponents.page_header
          title="Netboot Assets"
          subtitle="Boot files and transfer snapshots"
          server={@selected_server}
          online?={@service_online?}
          back={ServicePaths.server_path(@selected_server.id, :netboot)}
        />

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />
        <ManagementComponents.unavailable message="Asset mutation is unavailable because Management does not expose an exact owner revision" />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.card>
            <div class="text-sm text-on-surface-variant">Indexed assets</div><div class="text-2xl font-bold">
              {length(@assets)}
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Active transfers</div><div class="text-2xl font-bold">
              {Enum.count(@transfers, &(&1["state"] == "active"))}
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Completed transfers</div><div class="text-2xl font-bold">
              {Enum.count(@transfers, &(&1["state"] == "completed"))}
            </div>
          </.card>
        </div>

        <.card>
          <div class="mb-4 flex items-center justify-between gap-3">
            <h2 class="card-title">Boot assets</h2>
            <div class="flex gap-2">
              <button
                id="asset-upload-unavailable"
                type="button"
                disabled
                class="btn btn-primary btn-sm"
              >Upload unavailable</button>
              <button
                id="asset-rescan-unavailable"
                phx-click="rescan"
                disabled
                class="btn btn-outline btn-sm"
              >Rescan unavailable</button>
              <button id="export-files-csv" phx-click="export_files_csv" class="btn btn-ghost btn-sm">Export CSV</button>
            </div>
          </div>
          <form id="asset-upload-form" phx-submit="upload_asset" class="hidden">
            <button type="submit" disabled>Upload</button>
          </form>
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>Filename</th><th>Asset ID</th><th>Size</th><th>Blob digest</th><th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@assets == []}>
                  <td colspan="5" class="py-8 text-center text-on-surface-variant">
                    No assets in this Server snapshot
                  </td>
                </tr>
                <tr :for={asset <- @assets}>
                  <td class="font-mono">{asset["filename"]}</td>
                  <td>{asset["asset_id"]}</td>
                  <td>{format_size(asset["size"])}</td>
                  <td class="max-w-xs truncate font-mono" title={asset["blob_digest"]}>
                    {asset["blob_digest"]}
                  </td>
                  <td>
                    <button
                      phx-click="delete_asset"
                      phx-value-asset_id={asset["asset_id"]}
                      disabled
                      class="btn btn-ghost btn-xs text-error"
                    >Delete unavailable</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card>
          <div class="mb-4 flex items-center justify-between gap-3">
            <h2 class="card-title">Transfer history</h2>
            <button
              id="export-history-csv"
              phx-click="export_history_csv"
              class="btn btn-ghost btn-sm"
            >Export CSV</button>
          </div>
          <label class="input mb-4 flex items-center gap-2">
            <.dm_mdi name="magnify" class="h-4 w-4 opacity-70" />
            <input
              name="filter"
              value={@transfer_filter}
              phx-change="filter_history"
              placeholder="Filter transfers"
            />
          </label>
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th phx-click="sort_history" phx-value-field="transfer_id" class="cursor-pointer">
                    Transfer ID
                  </th>
                  <th phx-click="sort_history" phx-value-field="asset_id" class="cursor-pointer">
                    Asset
                  </th>
                  <th phx-click="sort_history" phx-value-field="device_id" class="cursor-pointer">
                    Device
                  </th>
                  <th phx-click="sort_history" phx-value-field="state" class="cursor-pointer">
                    State
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :if={displayed_transfers(assigns) == []}>
                  <td colspan="4" class="py-8 text-center text-on-surface-variant">
                    No transfers in this Server snapshot
                  </td>
                </tr>
                <tr :for={transfer <- displayed_transfers(assigns)}>
                  <td>{transfer["transfer_id"]}</td><td>{transfer["asset_id"]}</td><td>
                    {transfer["device_id"]}
                  </td><td>
                    <.badge color={transfer_color(transfer["state"])} size="sm">
                      {transfer["state"]}
                    </.badge>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  def filtered_history(history, ""), do: history

  def filtered_history(history, query) do
    query = String.downcase(query)

    Enum.filter(history, fn transfer ->
      transfer
      |> history_values()
      |> Enum.any?(&String.contains?(String.downcase(&1), query))
    end)
  end

  def sort_history(entries, field, dir) do
    sorted = Enum.sort_by(entries, &(history_value(&1, field) |> normalize_sort_value()))
    if dir == "desc", do: Enum.reverse(sorted), else: sorted
  end

  def flatten_tree(nodes), do: flatten_tree(nodes, [])
  def flatten_tree([], acc), do: Enum.reverse(acc)
  def flatten_tree([%{type: :file} = node | rest], acc), do: flatten_tree(rest, [node | acc])

  def flatten_tree([%{type: :directory} = node | rest], acc) do
    flatten_tree(rest, flatten_tree(node.children, acc))
  end

  defp load_assets(socket, server_id) do
    assets_result = ServerManagement.netboot_assets_list(server_id)
    transfers_result = ServerManagement.netboot_transfers_list(server_id)
    results = [assets_result, transfers_result]

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — Netboot Assets",
      assets: ManagementSupport.items(assets_result),
      transfers: ManagementSupport.items(transfers_result),
      management_error: ManagementSupport.first_error(results),
      cached_snapshot?: ManagementSupport.cached?(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at)
    )
  end

  defp displayed_transfers(assigns) do
    assigns.transfers
    |> filtered_history(assigns.transfer_filter)
    |> sort_history(assigns.transfer_sort_field, assigns.transfer_sort_dir)
  end

  defp history_values(transfer) do
    if Map.has_key?(transfer, "transfer_id") do
      Enum.map(~w(transfer_id asset_id device_id state), &to_string(transfer[&1] || ""))
    else
      [
        transfer |> Map.get(:file_path, "") |> to_string(),
        transfer |> Map.get(:client_addr) |> format_addr()
      ]
    end
  end

  defp history_value(transfer, "size"),
    do: Map.get(transfer, :bytes, Map.get(transfer, :total_size, 0))

  defp history_value(transfer, "client"), do: transfer |> Map.get(:client_addr) |> format_addr()
  defp history_value(transfer, "file"), do: Map.get(transfer, :file_path, "")
  defp history_value(transfer, "time"), do: Map.get(transfer, :completed_at, "")

  defp history_value(transfer, "transfer_id"),
    do: Map.get(transfer, "transfer_id", Map.get(transfer, :transfer_id, ""))

  defp history_value(transfer, "asset_id"),
    do: Map.get(transfer, "asset_id", Map.get(transfer, :asset_id, ""))

  defp history_value(transfer, "device_id"),
    do: Map.get(transfer, "device_id", Map.get(transfer, :device_id, ""))

  defp history_value(transfer, "state"),
    do: Map.get(transfer, "state", Map.get(transfer, :state, ""))

  defp history_value(_transfer, _field), do: ""

  defp normalize_sort_value(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp normalize_sort_value(value), do: value || ""

  defp format_addr(addr) when is_tuple(addr), do: to_string(:inet.ntoa(addr))
  defp format_addr(addr) when is_binary(addr), do: addr
  defp format_addr(_addr), do: ""

  defp transfer_color("completed"), do: "success"
  defp transfer_color("failed"), do: "error"
  defp transfer_color("active"), do: "info"
  defp transfer_color(_state), do: "ghost"

  defp format_size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_size(bytes) when is_integer(bytes) and bytes >= 1_024,
    do: "#{Float.round(bytes / 1_024, 1)} KB"

  defp format_size(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_size(_bytes), do: "-"

  defp toggle_dir("asc"), do: "desc"
  defp toggle_dir(_dir), do: "asc"
end
