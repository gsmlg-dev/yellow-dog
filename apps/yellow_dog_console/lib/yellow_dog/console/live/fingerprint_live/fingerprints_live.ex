defmodule YellowDog.Console.FingerprintLive.FingerprintsLive do
  @moduledoc """
  Fingerprint management and classification page for device type identification.

  Displays known device fingerprints (with vendor/OS classification), unknown
  fingerprints needing classification, and fingerprint patterns. Supports creating
  new device classes, assigning fingerprints to classes, bulk classification,
  search/filtering, and CSV export of fingerprint data.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Fingerprints",
       tab: "unknown",
       search_query: "",
       show_classify: false,
       selected_fp: nil,
       profiles: [],
       service_running: service_running?(YellowDog.Fingerprint)
     )
     |> load_data()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <.service_alert :if={not @service_running} service="Fingerprint" />

        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-4xl font-bold">Fingerprints</h1>
            <p class="mt-2 text-on-surface-variant">
              Manage device fingerprint database and classify unknown fingerprints
            </p>
          </div>
          <button
            phx-click="export_csv"
            id="export-csv"
            phx-hook="CsvDownload"
            class="btn btn-outline btn-sm"
          >
            Export CSV
          </button>
        </div>

        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <.card>
            <div class="text-sm text-on-surface-variant">Known Fingerprints</div>
            <div class="text-2xl font-bold text-success">{@known_count}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Unknown Fingerprints</div>
            <div class="text-2xl font-bold text-warning">{@unknown_count}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">V4 Database</div>
            <div class="text-2xl font-bold">{@stats.fingerprints_v4}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">V6 Database</div>
            <div class="text-2xl font-bold">{@stats.fingerprints_v6}</div>
          </.card>
        </div>

        <div role="tablist" class="tabs tabs-bordered">
          <a
            role="tab"
            class={"tab #{if @tab == "unknown", do: "tab-active"}"}
            phx-click="switch_tab"
            phx-value-tab="unknown"
          >
            Unknown ({@unknown_count})
          </a>
          <a
            role="tab"
            class={"tab #{if @tab == "known", do: "tab-active"}"}
            phx-click="switch_tab"
            phx-value-tab="known"
          >
            Known ({@known_count})
          </a>
        </div>

        <.card>
          <div class="mb-4">
            <label class="input flex items-center gap-2">
              <.dm_mdi name="magnify" class="h-4 w-4 opacity-70" />
              <input
                type="text"
                class="grow"
                placeholder="Search by vendor class, profile, or parameter list..."
                value={@search_query}
                phx-change="search"
                phx-debounce="300"
                name="search"
              />
            </label>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>Parameter List</th>
                  <th>Vendor Class</th>
                  <th>Profile</th>
                  <th>Confidence</th>
                  <th>Hits</th>
                  <th :if={@tab == "unknown"}>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@filtered_fingerprints == []}>
                  <td colspan="6" class="text-center text-on-surface-variant py-8">
                    No fingerprints found
                  </td>
                </tr>
                <tr :for={fp <- @filtered_fingerprints}>
                  <td class="font-mono text-xs max-w-xs truncate">
                    {format_param_list(fp)}
                  </td>
                  <td class="text-sm">{fp[:vendor_class] || "-"}</td>
                  <td>
                    <.badge :if={fp[:profile_id]} color="info" size="sm">
                      {fp[:profile_id]}
                    </.badge>
                    <span :if={!fp[:profile_id]} class="text-on-surface-variant">unclassified</span>
                  </td>
                  <td>{fp[:confidence] || 0}%</td>
                  <td>{fp[:hit_count] || 0}</td>
                  <td :if={@tab == "unknown"}>
                    <button
                      phx-click="classify"
                      phx-value-hash={fp[:hash]}
                      phx-disable-with="..."
                      class="btn btn-xs btn-primary"
                    >
                      Classify
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.modal :if={@show_classify} id="classify-modal" show>
          <h3 class="text-lg font-bold mb-4">Classify Fingerprint</h3>
          <form phx-submit="save_override">
            <input type="hidden" name="hash" value={@selected_fp} />
            <div class="form-group mb-4">
              <label class="form-label">Profile</label>
              <select name="profile_id" class="select w-full">
                <option :for={p <- @profiles} value={p.id}>{p.name}</option>
              </select>
            </div>
            <div class="form-group mb-4">
              <label class="form-label">Note (optional)</label>
              <input
                type="text"
                name="note"
                class="input"
                placeholder="e.g. Floor 3 sensors"
              />
            </div>
            <div class="flex justify-end gap-2 mt-4">
              <button type="button" phx-click="close_classify" class="btn btn-ghost">Cancel</button>
              <button type="submit" phx-disable-with="Saving..." class="btn btn-primary">
                Save Override
              </button>
            </div>
          </form>
        </.modal>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, socket |> assign(:tab, tab) |> apply_filters()}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> apply_filters()}
  end

  @impl true
  def handle_event("classify", %{"hash" => hash}, socket) do
    profiles =
      safe_call(YellowDog.Fingerprint, fn -> YellowDog.Fingerprint.list_profiles() end, [])

    {:noreply, assign(socket, show_classify: true, selected_fp: hash, profiles: profiles)}
  end

  @impl true
  def handle_event("close_classify", _params, socket) do
    {:noreply, assign(socket, show_classify: false, selected_fp: nil)}
  end

  @impl true
  def handle_event("save_override", %{"hash" => hash, "profile_id" => pid} = params, socket) do
    note = Map.get(params, "note", "")

    case safe_call(
           YellowDog.Fingerprint,
           fn -> YellowDog.Fingerprint.create_override(hash, pid, note) end,
           {:error, :service_unavailable}
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Override saved successfully")
         |> assign(show_classify: false, selected_fp: nil)
         |> load_data()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save override: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    csv = build_csv(socket.assigns.filtered_fingerprints)
    filename = "fingerprints_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp load_data(socket) do
    all =
      safe_call(YellowDog.Fingerprint, fn -> YellowDog.Fingerprint.list_fingerprints() end, [])

    stats =
      safe_call(YellowDog.Fingerprint, fn -> YellowDog.Fingerprint.database_stats() end, %{
        fingerprints_v4: 0,
        fingerprints_v6: 0,
        profiles: 0,
        overrides: 0
      })

    known = Enum.filter(all, &(&1[:profile_id] != nil))
    unknown = Enum.filter(all, &(&1[:profile_id] == nil))

    socket
    |> assign(:all_fingerprints, all)
    |> assign(:known_fingerprints, known)
    |> assign(:unknown_fingerprints, unknown)
    |> assign(:known_count, length(known))
    |> assign(:unknown_count, length(unknown))
    |> assign(:stats, stats)
    |> apply_filters()
  end

  defp apply_filters(socket) do
    source =
      case socket.assigns.tab do
        "unknown" -> socket.assigns[:unknown_fingerprints] || []
        "known" -> socket.assigns[:known_fingerprints] || []
        _ -> socket.assigns[:all_fingerprints] || []
      end

    filtered = filter_by_search(source, socket.assigns.search_query)
    assign(socket, :filtered_fingerprints, filtered)
  end

  def filter_by_search(fps, ""), do: fps

  def filter_by_search(fps, query) do
    q = String.downcase(query)

    Enum.filter(fps, fn fp ->
      (fp[:vendor_class] && String.contains?(String.downcase(fp[:vendor_class]), q)) ||
        (fp[:profile_id] && String.contains?(String.downcase(fp[:profile_id]), q)) ||
        (fp[:parameter_list] && String.contains?(inspect(fp[:parameter_list]), q))
    end)
  end

  defp format_param_list(fp) do
    case fp[:parameter_list] do
      list when is_list(list) -> Enum.join(list, ", ")
      _ -> "-"
    end
  end

  defp build_csv(fingerprints) do
    header = "Parameter List,Vendor Class,Profile,Confidence,Hit Count\r\n"

    rows =
      Enum.map_join(fingerprints, "\r\n", fn fp ->
        [
          csv_escape(format_param_list(fp)),
          csv_escape(fp[:vendor_class] || ""),
          csv_escape(fp[:profile_id] || "unknown"),
          csv_escape(to_string(fp[:confidence] || 0)),
          csv_escape(to_string(fp[:hit_count] || 0))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
