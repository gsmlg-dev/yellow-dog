defmodule YellowDog.Console.NetbootLive.TftpLive do
  @moduledoc "TFTP server status — server config, file browser, active transfers."
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.NetbootComponents, only: [format_size: 1]
  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:tftp")
    end

    {:ok,
     socket
     |> assign(
       page_title: "TFTP Server",
       upload_path: "",
       active_transfers_map: %{},
       transfer_history: [],
       history_filter: "",
       history_sort_field: "time",
       history_sort_dir: "desc",
       service_running: service_running?(YellowDog.Netboot.TFTP.Server)
     )
     |> allow_upload(:boot_asset,
       accept: :any,
       max_entries: 5,
       max_file_size: 500_000_000
     )
     |> load_data()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <.service_alert :if={not @service_running} service="Netboot TFTP" navigate="/settings" />

        <div>
          <h1 class="text-4xl font-bold">TFTP Server</h1>
          <p class="mt-2 text-base-content/70">
            Boot file serving via TFTP protocol
          </p>
        </div>

        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Status</div>
            <div :if={@status.running} class="stat-value text-success">Running</div>
            <div :if={!@status.running} class="stat-value text-error">Stopped</div>
          </div>
          <div class="stat">
            <div class="stat-title">Port</div>
            <div class="stat-value font-mono">{@status.port}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Files Indexed</div>
            <div class="stat-value">{@status.file_count}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Active Transfers</div>
            <div class="stat-value">{@status.active_transfers}</div>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.card>
            <h2 class="card-title mb-4">Configuration</h2>
            <div class="space-y-2">
              <div class="flex justify-between">
                <span class="text-base-content/70">Root Directory</span>
                <span class="font-mono text-sm">{@status.root_dir}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/70">Listen Port</span>
                <span class="font-mono">{@status.port}</span>
              </div>
            </div>
            <div class="mt-4">
              <button phx-click="rescan" class="btn btn-outline btn-sm">
                Rescan Files
              </button>
            </div>
          </.card>

          <.card>
            <h2 class="card-title mb-4">Upload Boot Assets</h2>
            <.form for={%{}} phx-change="validate_upload" phx-submit="save_upload" class="space-y-3">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Target Directory (relative to TFTP root)</span>
                </label>
                <input
                  type="text"
                  name="upload_path"
                  value={@upload_path}
                  placeholder="e.g. nixos/ or rescue/"
                  class="input input-bordered input-sm w-full font-mono"
                />
              </div>

              <div
                class="border-2 border-dashed border-base-300 rounded-lg p-4 text-center"
                phx-drop-target={@uploads.boot_asset.ref}
              >
                <.live_file_input
                  upload={@uploads.boot_asset}
                  class="file-input file-input-bordered file-input-sm w-full"
                />
                <p class="text-xs text-base-content/50 mt-1">
                  Max 500 MB per file, up to 5 files
                </p>
              </div>

              <%= for entry <- @uploads.boot_asset.entries do %>
                <div class="flex items-center gap-2 text-sm">
                  <span class="font-mono flex-1 truncate">{entry.client_name}</span>
                  <span class="text-base-content/50">{format_size(entry.client_size)}</span>
                  <progress class="progress progress-primary w-20" value={entry.progress} max="100" />
                  <button
                    type="button"
                    phx-click="cancel_upload"
                    phx-value-ref={entry.ref}
                    class="btn btn-ghost btn-xs text-error"
                    aria-label="Cancel upload"
                  >
                    &times;
                  </button>
                </div>
                <%= for err <- upload_errors(@uploads.boot_asset, entry) do %>
                  <p class="text-xs text-error">{upload_error_to_string(err)}</p>
                <% end %>
              <% end %>

              <button
                type="submit"
                class={["btn btn-primary btn-sm", @uploads.boot_asset.entries == [] && "btn-disabled"]}
                disabled={@uploads.boot_asset.entries == []}
              >
                Upload Files
              </button>
            </.form>
          </.card>
        </div>

        <.card>
          <h2 class="card-title mb-4">Active Transfers</h2>
          <div :if={@active_transfers_map == %{}} class="text-base-content/50">
            No active transfers
          </div>
          <div :if={@active_transfers_map != %{}} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Client</th>
                  <th>File</th>
                  <th>Size</th>
                  <th>Started</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{_key, t} <- @active_transfers_map}>
                  <td class="font-mono text-sm">{format_addr(t.client_addr)}</td>
                  <td class="font-mono text-sm">{t.file_path}</td>
                  <td>{format_size(t.total_size)}</td>
                  <td class="text-sm">{format_started(t.started_at)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card>
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">Transfer History</h2>
            <div class="flex items-center gap-2">
              <input
                type="text"
                class="input input-bordered input-sm w-64"
                placeholder="Filter by client or file..."
                value={@history_filter}
                phx-change="filter_history"
                phx-debounce="300"
                name="filter"
              />
              <button
                phx-click="export_history_csv"
                id="export-history-csv"
                phx-hook="CsvDownload"
                class="btn btn-outline btn-sm"
              >
                Export CSV
              </button>
            </div>
          </div>
          <div
            :if={sorted_history(@transfer_history, @history_filter, @history_sort_field, @history_sort_dir) == []}
            class="text-base-content/50"
          >
            No transfer history
          </div>
          <div
            :if={sorted_history(@transfer_history, @history_filter, @history_sort_field, @history_sort_dir) != []}
            class="overflow-x-auto"
          >
            <table class="table table-sm table-zebra">
              <thead>
                <tr>
                  <.history_sort_header field="client" label="Client" sort_field={@history_sort_field} sort_dir={@history_sort_dir} />
                  <.history_sort_header field="file" label="File" sort_field={@history_sort_field} sort_dir={@history_sort_dir} />
                  <.history_sort_header field="size" label="Size" sort_field={@history_sort_field} sort_dir={@history_sort_dir} />
                  <.history_sort_header field="duration" label="Duration" sort_field={@history_sort_field} sort_dir={@history_sort_dir} />
                  <th>Speed</th>
                  <.history_sort_header field="status" label="Status" sort_field={@history_sort_field} sort_dir={@history_sort_dir} />
                </tr>
              </thead>
              <tbody>
                <tr :for={t <- sorted_history(@transfer_history, @history_filter, @history_sort_field, @history_sort_dir)}>
                  <td class="font-mono text-sm">{format_addr(t.client_addr)}</td>
                  <td class="font-mono text-sm">{t.file_path}</td>
                  <td>{format_size(t[:bytes] || t[:total_size] || 0)}</td>
                  <td>{format_duration(t[:duration])}</td>
                  <td>{format_speed(t[:bytes], t[:duration])}</td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      if(t[:status] == :error, do: "badge-error", else: "badge-success")
                    ]}>
                      {if t[:status] == :error, do: "Failed", else: "Complete"}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card>
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">
              File Browser
              <.badge :if={@status.file_count > 0} color="ghost" size="sm">{@status.file_count} files</.badge>
            </h2>
            <button
              phx-click="export_files_csv"
              id="export-files-csv"
              phx-hook="CsvDownload"
              class="btn btn-outline btn-sm"
            >
              Export CSV
            </button>
          </div>
          <div :if={@file_tree == []} class="text-base-content/50 text-center py-4">
            <p>No files found in TFTP root</p>
            <p class="text-sm mt-1">Upload boot assets using the form above or place files in the TFTP root directory</p>
          </div>
          <div :if={@file_tree != []} class="text-sm">
            <.file_tree_node :for={node <- @file_tree} node={node} />
          </div>
        </.card>

        <div class="text-xs text-base-content/50 flex justify-end">
          <span :if={connected?(@socket)} class="flex items-center gap-1">
            <span class="w-2 h-2 bg-success rounded-full animate-pulse"></span> Live
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp file_tree_node(%{node: %{type: :directory}} = assigns) do
    ~H"""
    <details class="ml-2">
      <summary class="cursor-pointer hover:text-primary py-0.5">
        {@node.name}/
      </summary>
      <div class="ml-2 border-l border-base-300 pl-2">
        <.file_tree_node :for={child <- @node.children} node={child} />
      </div>
    </details>
    """
  end

  defp file_tree_node(%{node: %{type: :file}} = assigns) do
    ~H"""
    <div class="ml-2 py-0.5 flex justify-between items-center">
      <span class="font-mono">{@node.name}</span>
      <span class="flex items-center gap-2">
        <span class="text-base-content/50">{format_size(@node.size)}</span>
        <button
          phx-click="delete_file"
          phx-value-path={@node.path}
          data-confirm={"Delete #{@node.path}?"}
          class="btn btn-ghost btn-xs text-error"
          aria-label={"Delete #{@node.name}"}
        >
          &times;
        </button>
      </span>
    </div>
    """
  end

  @impl true
  def handle_event("validate_upload", %{"upload_path" => path}, socket) do
    {:noreply, assign(socket, :upload_path, path)}
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_upload", _params, socket) do
    prefix = String.trim(socket.assigns.upload_path)

    uploaded =
      consume_uploaded_entries(socket, :boot_asset, fn %{path: tmp_path}, entry ->
        dest_path =
          if prefix != "" do
            Path.join(prefix, entry.client_name)
          else
            entry.client_name
          end

        result =
          safe_call(
            YellowDog.Netboot.Asset.Store,
            fn -> YellowDog.Netboot.Asset.Store.upload_file(dest_path, tmp_path) end,
            {:error, :service_unavailable}
          )

        case result do
          :ok -> {:ok, dest_path}
          error -> {:ok, {:error, dest_path, error}}
        end
      end)

    {ok, errors} =
      Enum.split_with(uploaded, fn
        {:error, _, _} -> false
        _ -> true
      end)

    socket =
      socket
      |> load_data()
      |> assign(:upload_path, "")

    socket =
      cond do
        errors != [] ->
          put_flash(socket, :error, "Failed to upload #{length(errors)} file(s)")

        ok != [] ->
          put_flash(socket, :info, "Uploaded #{length(ok)} file(s) successfully")

        true ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :boot_asset, ref)}
  end

  @impl true
  def handle_event("rescan", _params, socket) do
    safe_call(
      YellowDog.Netboot.TFTP.FileIndex,
      fn ->
        root = YellowDog.Netboot.TFTP.Server.root_dir()
        YellowDog.Netboot.TFTP.FileIndex.scan(root)
      end,
      :ok
    )

    {:noreply, socket |> put_flash(:info, "File index rescanned") |> load_data()}
  end

  def handle_event("filter_history", %{"filter" => query}, socket) do
    {:noreply, assign(socket, :history_filter, query)}
  end

  def handle_event("sort_history", %{"field" => field}, socket) do
    dir =
      if socket.assigns.history_sort_field == field,
        do: toggle_dir(socket.assigns.history_sort_dir),
        else: "asc"

    {:noreply, assign(socket, history_sort_field: field, history_sort_dir: dir)}
  end

  def handle_event("export_history_csv", _params, socket) do
    entries = filtered_history(socket.assigns.transfer_history, socket.assigns.history_filter)
    csv = build_history_csv(entries)
    filename = "tftp_transfers_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  def handle_event("export_files_csv", _params, socket) do
    files = flatten_tree(socket.assigns.file_tree)
    csv = build_files_csv(files)
    filename = "tftp_files_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  def handle_event("delete_file", %{"path" => path}, socket) do
    result =
      safe_call(
        YellowDog.Netboot.Asset.Store,
        fn -> YellowDog.Netboot.Asset.Store.delete_file(path) end,
        {:error, :service_unavailable}
      )

    case result do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Deleted #{path}") |> load_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:tftp_transfer_started, meta}, socket) do
    key = transfer_key(meta)
    entry = Map.put(meta, :started_at, DateTime.utc_now())
    active = Map.put(socket.assigns.active_transfers_map, key, entry)
    {:noreply, assign(socket, :active_transfers_map, active)}
  end

  def handle_info({:tftp_transfer_complete, meta}, socket) do
    key = transfer_key(meta)
    active = Map.delete(socket.assigns.active_transfers_map, key)
    history = [meta | socket.assigns.transfer_history] |> Enum.take(50)
    {:noreply, socket |> assign(active_transfers_map: active, transfer_history: history)}
  end

  def handle_info(_msg, socket), do: {:noreply, load_data(socket)}

  defp load_data(socket) do
    status =
      safe_call(
        YellowDog.Netboot.TFTP.Server,
        fn ->
          YellowDog.Netboot.TFTP.Server.status()
        end,
        %{running: false, port: 69, file_count: 0, active_transfers: 0, root_dir: "-"}
      )

    tree =
      safe_call(
        YellowDog.Netboot.Asset.Store,
        fn ->
          YellowDog.Netboot.Asset.Store.file_tree()
        end,
        []
      )

    socket
    |> assign(:status, status)
    |> assign(:file_tree, tree)
  end

  defp upload_error_to_string(:too_large), do: "File is too large (max 500 MB)"
  defp upload_error_to_string(:too_many_files), do: "Too many files (max 5)"
  defp upload_error_to_string(:external_client_failure), do: "Upload failed"
  defp upload_error_to_string(err), do: "Error: #{inspect(err)}"

  defp format_addr(addr) when is_tuple(addr), do: to_string(:inet.ntoa(addr))
  defp format_addr(addr) when is_binary(addr), do: addr
  defp format_addr(_), do: "-"

  defp format_started(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_started(_), do: "-"

  defp format_duration(nil), do: "-"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp format_speed(nil, _), do: "-"
  defp format_speed(_, nil), do: "-"
  defp format_speed(_, 0), do: "-"

  defp format_speed(bytes, ms) do
    bps = bytes / (ms / 1000)
    format_size(round(bps)) <> "/s"
  end

  defp transfer_key(meta) do
    {Map.get(meta, :client_addr), Map.get(meta, :file_path)}
  end

  defp history_sort_header(assigns) do
    ~H"""
    <th
      phx-click="sort_history"
      phx-value-field={@field}
      class="cursor-pointer select-none hover:bg-base-200"
    >
      <div class="flex items-center gap-1">
        {@label}
        <span :if={@sort_field == @field} class="text-xs">
          {if @sort_dir == "asc", do: "\u25B2", else: "\u25BC"}
        </span>
      </div>
    </th>
    """
  end

  defp toggle_dir("asc"), do: "desc"
  defp toggle_dir(_), do: "asc"

  def filtered_history(history, ""), do: history

  def filtered_history(history, query) do
    q = String.downcase(query)

    Enum.filter(history, fn t ->
      file = Map.get(t, :file_path, "") |> to_string() |> String.downcase()
      addr = format_addr(Map.get(t, :client_addr)) |> String.downcase()
      String.contains?(file, q) || String.contains?(addr, q)
    end)
  end

  def sorted_history(history, filter, sort_field, sort_dir) do
    history
    |> filtered_history(filter)
    |> sort_history(sort_field, sort_dir)
  end

  def sort_history(entries, field, dir) do
    sorter = history_sort_key(field)
    sorted = Enum.sort_by(entries, sorter)
    if dir == "desc", do: Enum.reverse(sorted), else: sorted
  end

  defp history_sort_key("client"), do: &format_addr(&1[:client_addr])
  defp history_sort_key("file"), do: &to_string(&1[:file_path] || "")
  defp history_sort_key("size"), do: &(&1[:bytes] || &1[:total_size] || 0)
  defp history_sort_key("duration"), do: &(&1[:duration] || 0)
  defp history_sort_key("status"), do: &to_string(&1[:status] || "")
  defp history_sort_key(_), do: &(&1[:bytes] || 0)

  defp build_history_csv(entries) do
    header = "Client,File,Size,Duration,Speed,Status\r\n"

    rows =
      Enum.map_join(entries, "\r\n", fn t ->
        bytes = t[:bytes] || t[:total_size] || 0
        status = if t[:status] == :error, do: "Failed", else: "Complete"

        [
          csv_escape(format_addr(t.client_addr)),
          csv_escape(to_string(t.file_path)),
          csv_escape(format_size(bytes)),
          csv_escape(format_duration(t[:duration])),
          csv_escape(format_speed(t[:bytes], t[:duration])),
          csv_escape(status)
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  defp build_files_csv(files) do
    header = "Path,Size\r\n"

    rows =
      Enum.map_join(files, "\r\n", fn f ->
        [csv_escape(f.path), csv_escape(format_size(f.size))]
        |> Enum.join(",")
      end)

    header <> rows
  end

  def flatten_tree(nodes), do: flatten_tree(nodes, [])

  def flatten_tree([], acc), do: Enum.reverse(acc)

  def flatten_tree([%{type: :file} = node | rest], acc) do
    flatten_tree(rest, [node | acc])
  end

  def flatten_tree([%{type: :directory} = node | rest], acc) do
    acc = flatten_tree(node.children, acc)
    flatten_tree(rest, acc)
  end
end
