defmodule YellowDog.Console.MacDatabaseLive do
  @moduledoc """
  LiveView for managing the MAC manufacturer (OUI) database.

  Displays the current database status, entry count, and source.
  Provides download/update functionality to fetch the latest Wireshark
  manuf.txt database.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Tasks

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "MAC Database",
       db_info: nil,
       downloading: false
     )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :db_info, load_info())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl">
        <div class="flex justify-between items-center mb-6">
          <div>
            <h1 class="text-3xl font-bold">MAC Database</h1>
            <p class="text-sm text-on-surface-variant mt-1">
              Manage the OUI manufacturer database for MAC address lookups
            </p>
          </div>
          <button phx-click="refresh" class="btn btn-ghost btn-sm">
            <.dm_mdi name="refresh" class="h-5 w-5" /> Refresh
          </button>
        </div>

        <div class="card bg-surface shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-lg">Update Database</h2>
            <p class="text-sm text-on-surface-variant">
              Queue the Wireshark OUI database update job. The task runner downloads
              manuf.txt and reloads MAC prefix lookups after validation.
            </p>
            <div class="flex flex-wrap gap-3 mt-4">
              <button
                phx-click="download"
                class="btn btn-primary"
                disabled={@downloading}
              >
                <.dm_mdi name="calendar-sync" class="h-5 w-5" /> Queue MAC/OUI sync
              </button>
              <.link navigate="/system/tasks/mac" class="btn btn-ghost">
                <.dm_mdi name="history" class="h-5 w-5" /> MAC/OUI sync
              </.link>
              <button
                phx-click="reload"
                class="btn btn-ghost"
                disabled={@downloading}
              >
                <.dm_mdi name="reload" class="h-5 w-5" /> Reload from Disk
              </button>
            </div>
            <p class="text-xs text-on-surface-variant mt-2">
              Source: <span class="font-mono">wireshark.org</span>
              — Based on IEEE OUI assignments (Wireshark manuf format)
            </p>
          </div>
        </div>

        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title text-lg">Database Status</h2>
            <%= if @db_info do %>
              <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-4">
                <div>
                  <div class="text-xs text-on-surface-variant">Source</div>
                  <div class="font-semibold text-sm flex items-center gap-1">
                    <.source_badge source={@db_info.source} />
                  </div>
                </div>
                <div>
                  <div class="text-xs text-on-surface-variant">Entries</div>
                  <div class="font-semibold text-sm">{format_number(@db_info.entry_count)}</div>
                </div>
                <div>
                  <div class="text-xs text-on-surface-variant">Loaded At</div>
                  <div class="font-semibold text-sm">{format_datetime(@db_info.loaded_at)}</div>
                </div>
                <div>
                  <div class="text-xs text-on-surface-variant">File Size</div>
                  <div class="font-semibold text-sm">{format_file_size(@db_info.file_info)}</div>
                </div>
                <div>
                  <div class="text-xs text-on-surface-variant">File Modified</div>
                  <div class="font-semibold text-sm">{format_file_mtime(@db_info.file_info)}</div>
                </div>
                <div>
                  <div class="text-xs text-on-surface-variant">File Path</div>
                  <div class="font-mono text-xs break-all">{@db_info.manuf_path}</div>
                </div>
              </div>
            <% else %>
              <div class="text-center py-12 text-on-surface-variant">
                <.dm_mdi name="database-off" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                <p>Database information unavailable.</p>
              </div>
            <% end %>
          </div>
        </div>

        <div class="card bg-surface shadow-xl mt-6">
          <div class="card-body">
            <h2 class="card-title text-lg">Test Lookup</h2>
            <p class="text-sm text-on-surface-variant mb-4">
              Verify the database by looking up a MAC address.
            </p>
            <form phx-submit="test_lookup" class="flex gap-2">
              <input
                type="text"
                name="mac"
                placeholder="e.g. 00:00:0A:BB:28:FC"
                class="input flex-1"
              />
              <button type="submit" class="btn btn-ghost">
                <.dm_mdi name="magnify" class="h-5 w-5" /> Lookup
              </button>
            </form>
            <div :if={assigns[:test_result]} class="mt-4">
              <%= case @test_result do %>
                <% {:ok, short, full} -> %>
                  <div class="alert alert-success">
                    <div>
                      <div class="font-bold">{full}</div>
                      <div class="text-sm">{short}</div>
                    </div>
                  </div>
                <% :error -> %>
                  <div class="alert alert-warning">
                    <span>No vendor found for this MAC address</span>
                  </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp source_badge(%{source: :file} = assigns) do
    ~H"""
    <span class="badge badge-success badge-sm">File</span>
    <span>Downloaded manuf.txt</span>
    """
  end

  defp source_badge(%{source: :compiled} = assigns) do
    ~H"""
    <span class="badge badge-info badge-sm">Compiled</span>
    <span>Built-in (gsmlg_mac)</span>
    """
  end

  defp source_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">Unknown</span>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :db_info, load_info())}
  end

  def handle_event("download", _params, socket) do
    case Tasks.enqueue(:mac) do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :info, "MAC/OUI sync queued.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Queue failed: #{inspect(reason)}")}
    end
  end

  def handle_event("reload", _params, socket) do
    ensure_oui_database_started()

    case YellowDog.Fingerprint.OuiDatabase.reload() do
      :ok ->
        {:noreply,
         socket
         |> assign(:db_info, load_info())
         |> put_flash(:info, "Database reloaded from disk.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reload failed: #{inspect(reason)}")}
    end
  end

  def handle_event("test_lookup", %{"mac" => mac}, socket) do
    mac = String.trim(mac)

    result =
      if mac == "" do
        nil
      else
        YellowDog.Fingerprint.OuiDatabase.lookup(mac)
      end

    {:noreply, assign(socket, :test_result, result)}
  end

  # --- Private Helpers ---

  defp ensure_oui_database_started do
    case GenServer.whereis(YellowDog.Fingerprint.OuiDatabase) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        data_dir =
          Application.get_env(:yellow_dog_fingerprint, :data_dir, "data/fingerprint")

        case YellowDog.Fingerprint.OuiDatabase.start_link(data_dir: data_dir) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp load_info do
    ensure_oui_database_started()

    try do
      YellowDog.Fingerprint.OuiDatabase.info()
    catch
      :exit, _ -> nil
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(_), do: "—"

  defp format_file_size(%{size: size}) when is_integer(size) do
    cond do
      size >= 1_048_576 -> "#{Float.round(size / 1_048_576, 1)} MB"
      size >= 1024 -> "#{Float.round(size / 1024, 1)} KB"
      true -> "#{size} B"
    end
  end

  defp format_file_size(_), do: "— (no file on disk)"

  defp format_file_mtime(%{mtime: mtime}) do
    case NaiveDateTime.from_erl(mtime) do
      {:ok, ndt} -> Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
      _ -> "—"
    end
  end

  defp format_file_mtime(_), do: "—"
end
