defmodule YellowDog.Console.IpDatabaseLive do
  @moduledoc """
  LiveView for managing GeoIP MMDB databases.

  Displays loaded databases with metadata, file info, and provides
  download/update functionality for DB-IP lite databases.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias GeoIpDb.Database
  alias YellowDog.Tasks

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "IP Database",
       databases: [],
       downloading: nil
     )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :databases, load_databases())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl">
        <div class="flex justify-between items-center mb-6">
          <div>
            <h1 class="text-3xl font-bold">IP Database</h1>
            <p class="text-sm text-on-surface-variant mt-1">
              Manage GeoIP MMDB databases for IP geolocation lookups
            </p>
          </div>
          <button phx-click="refresh" class="btn btn-ghost btn-sm">
            <.dm_mdi name="refresh" class="h-5 w-5" /> Refresh
          </button>
        </div>

        <div class="card bg-surface shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-lg">Download Databases</h2>
            <p class="text-sm text-on-surface-variant">
              Queue DB-IP lite database updates. These jobs download IP-to-location MMDB
              files and load them through the task runner.
            </p>
            <div class="flex flex-wrap gap-3 mt-4">
              <button
                :for={type <- [:city, :country]}
                phx-click="download"
                phx-value-type={type}
                class="btn btn-primary"
                disabled={@downloading != nil}
              >
                <.dm_mdi name="calendar-sync" class="h-5 w-5" /> Queue {sync_label(type)}
              </button>
              <.link navigate="/system/tasks/ip_city" class="btn btn-ghost">
                <.dm_mdi name="history" class="h-5 w-5" /> IP City sync
              </.link>
              <.link navigate="/system/tasks/ip_country" class="btn btn-ghost">
                <.dm_mdi name="history" class="h-5 w-5" /> IP Country sync
              </.link>
            </div>
            <p class="text-xs text-on-surface-variant mt-2">
              Source: <span class="font-mono">download.db-ip.com</span>
              — Free with attribution (CC BY 4.0)
            </p>
          </div>
        </div>

        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title text-lg">Loaded Databases</h2>
            <%= if @databases == [] do %>
              <div class="text-center py-12 text-on-surface-variant">
                <.dm_mdi name="database-off" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                <p>No databases loaded. Download one above to get started.</p>
              </div>
            <% else %>
              <div class="grid gap-4 mt-2">
                <.database_card
                  :for={db <- @databases}
                  db={db}
                  downloading={@downloading}
                />
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp database_card(assigns) do
    ~H"""
    <div class="card card-bordered bg-surface-container">
      <div class="card-body">
        <div class="flex justify-between items-start">
          <div>
            <h3 class="font-bold text-lg flex items-center gap-2">
              <.dm_mdi name="earth" class="w-5 h-5 text-primary" />
              {type_label(@db.name)}
            </h3>
            <span class="badge badge-sm badge-ghost font-mono">{@db.name}</span>
          </div>
          <div class="flex gap-1">
            <button
              phx-click="download"
              phx-value-type={@db.name}
              class="btn btn-ghost btn-sm"
              disabled={@downloading != nil}
              title="Update database"
            >
              <.dm_mdi name="calendar-sync" class="h-4 w-4" /> Queue
            </button>
            <button
              phx-click="unload"
              phx-value-name={@db.name}
              class="btn btn-ghost btn-sm text-error"
              data-confirm={"Unload the #{@db.name} database? It will need to be re-downloaded to use again."}
            >
              <.dm_mdi name="delete" class="h-4 w-4" />
            </button>
          </div>
        </div>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-4">
          <div>
            <div class="text-xs text-on-surface-variant">Database Type</div>
            <div class="font-semibold text-sm">{@db.metadata[:database_type] || "—"}</div>
          </div>
          <div>
            <div class="text-xs text-on-surface-variant">Build Date</div>
            <div class="font-semibold text-sm">{format_epoch(@db.metadata[:build_epoch])}</div>
          </div>
          <div>
            <div class="text-xs text-on-surface-variant">IP Version</div>
            <div class="font-semibold text-sm">{@db.metadata[:ip_version] || "—"}</div>
          </div>
          <div>
            <div class="text-xs text-on-surface-variant">Node Count</div>
            <div class="font-semibold text-sm">
              {if @db.metadata[:node_count], do: format_number(@db.metadata[:node_count]), else: "—"}
            </div>
          </div>
          <div>
            <div class="text-xs text-on-surface-variant">File Size</div>
            <div class="font-semibold text-sm">{format_bytes(@db.file_size)}</div>
          </div>
          <div>
            <div class="text-xs text-on-surface-variant">Record Size</div>
            <div class="font-semibold text-sm">
              <%= if @db.metadata[:record_size] do %>
                {@db.metadata[:record_size]} bits
              <% else %>
                —
              <% end %>
            </div>
          </div>
          <div>
            <div class="text-xs text-on-surface-variant">Languages</div>
            <div class="font-semibold text-sm">
              {(@db.metadata[:languages] || []) |> Enum.join(", ")}
            </div>
          </div>
          <div>
            <div class="text-xs text-on-surface-variant">File Path</div>
            <div class="font-mono text-xs break-all">{@db.path}</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :databases, load_databases())}
  end

  def handle_event("download", %{"type" => type}, socket) do
    type_atom = validated_type(type)

    case Tasks.enqueue(ip_task(type_atom)) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{sync_label(type_atom)} sync queued.")
         |> assign(:databases, load_databases())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Queue failed: #{inspect(reason)}")}
    end
  end

  def handle_event("unload", %{"name" => name}, socket) do
    type_atom = validated_type(name)
    Database.unload(type_atom)

    {:noreply,
     socket
     |> put_flash(:info, "Database #{name} unloaded.")
     |> assign(:databases, load_databases())}
  end

  # --- Private Helpers ---

  @valid_types ~w(city country)
  defp validated_type(type) when type in @valid_types, do: String.to_existing_atom(type)

  defp load_databases do
    Database.list_databases()
    |> Enum.map(fn name ->
      metadata =
        case Database.get_metadata(name) do
          {:ok, meta} -> meta
          _ -> %{}
        end

      {path, file_size} =
        case Database.file_info(name) do
          {:ok, info} -> {info.path, info.size}
          _ -> {Database.database_path(name), nil}
        end

      %{name: name, metadata: metadata, path: path, file_size: file_size}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp type_label(:city), do: "City (Lite)"
  defp type_label(:country), do: "Country (Lite)"
  defp type_label(other), do: to_string(other)

  defp sync_label(:city), do: "IP City"
  defp sync_label(:country), do: "IP Country"

  defp ip_task(:city), do: :ip_city
  defp ip_task(:country), do: :ip_country

  defp format_epoch(nil), do: "—"
  defp format_epoch(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_epoch(epoch) when is_integer(epoch),
    do: epoch |> DateTime.from_unix!() |> format_epoch()

  defp format_epoch(_), do: "—"

  defp format_bytes(nil), do: "—"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"
end
