defmodule YellowDog.ManagementUI.MacDatabaseLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.MacDatabase

  @impl true
  def mount(_params, _session, socket) do
    server = Application.get_env(:yellow_dog_management, :mac_database_server, MacDatabase)

    {:ok,
     socket
     |> assign(
       page_title: "MAC Database",
       database_server: server,
       db_info: nil,
       reloading: false,
       query: "",
       lookup_result: nil,
       lookup_error: nil,
       error: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("reload", _params, socket) do
    cond do
      socket.assigns.reloading ->
        {:noreply, socket}

      is_nil(socket.assigns.db_info) ->
        {:noreply, assign(socket, :error, "Database service unavailable.")}

      not socket.assigns.db_info.configured ->
        {:noreply, assign(socket, :error, "No MAC database file is configured.")}

      socket.assigns.db_info.status == :loading ->
        {:noreply, assign(socket, :error, "Database reload is already in progress.")}

      true ->
        server = socket.assigns.database_server

        {:noreply,
         socket
         |> assign(reloading: true, error: nil)
         |> start_async(:reload_mac_database, fn -> MacDatabase.reload(server) end)}
    end
  end

  def handle_event("test_lookup", %{"mac" => mac}, socket)
      when is_binary(mac) and byte_size(mac) <= 256 do
    socket = assign(socket, query: mac, lookup_result: nil, lookup_error: nil)

    case lookup(String.trim(mac), socket.assigns.database_server) do
      {:ok, short, full} ->
        {:noreply, assign(socket, :lookup_result, %{short: short, full: full})}

      :error ->
        {:noreply, assign(socket, :lookup_error, "No vendor found for this MAC address")}

      {:error, :invalid_mac} ->
        {:noreply, assign(socket, :lookup_error, "Invalid MAC address")}

      {:error, reason} ->
        {:noreply, assign(socket, :lookup_error, "Lookup failed: #{inspect(reason)}")}
    end
  end

  def handle_event("test_lookup", _params, socket) do
    {:noreply, assign(socket, lookup_result: nil, lookup_error: "Invalid MAC address")}
  end

  def handle_event("download", _params, socket) do
    {:noreply,
     assign(
       socket,
       :error,
       "Downloads and queued MAC/OUI sync jobs are not migrated. Durable task storage authorization is pending; no job was queued."
     )}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:reload_mac_database, {:ok, result}, socket) do
    error =
      case result do
        :ok -> nil
        {:error, reason} -> "Reload failed: #{inspect(reason)}"
      end

    {:noreply, socket |> refresh() |> assign(reloading: false, error: error, lookup_result: nil)}
  end

  def handle_async(:reload_mac_database, {:exit, reason}, socket) do
    {:noreply,
     socket |> refresh() |> assign(reloading: false, error: "Reload failed: #{inspect(reason)}")}
  end

  defp refresh(socket) do
    case info(socket.assigns.database_server) do
      {:ok, db_info} ->
        assign(socket, db_info: db_info, error: nil)

      {:error, reason} ->
        assign(socket, db_info: nil, error: "Database service unavailable: #{inspect(reason)}")
    end
  end

  defp info(server) do
    {:ok, MacDatabase.info(server)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp lookup(mac, server) do
    case info(server) do
      {:ok, _info} -> MacDatabase.lookup(mac, server)
      {:error, _reason} -> {:error, :database_unavailable}
    end
  catch
    :exit, _reason -> {:error, :database_unavailable}
  end

  defp datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  defp datetime(_value), do: "—"

  defp file_mtime(%{mtime: mtime}) when is_integer(mtime) do
    case DateTime.from_unix(mtime) do
      {:ok, value} -> datetime(value)
      {:error, _reason} -> "—"
    end
  end

  defp file_mtime(_info), do: "—"

  defp file_size(%{size: size}) when is_integer(size) do
    cond do
      size >= 1_048_576 -> "#{Float.round(size / 1_048_576, 1)} MB (#{size} bytes)"
      size >= 1024 -> "#{Float.round(size / 1024, 1)} KB (#{size} bytes)"
      true -> "#{size} B"
    end
  end

  defp file_size(_info), do: "— (no successfully loaded file)"

  defp source_label(:file), do: "File"
  defp source_label(:compiled), do: "Compiled"
  defp source_class(:file), do: "badge badge-success badge-sm"
  defp source_class(:compiled), do: "badge badge-info badge-sm"

  defp database_error(%{last_error: nil}), do: nil
  defp database_error(%{last_error: reason}), do: "Last load failed: #{inspect(reason)}"
  defp database_error(nil), do: nil

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :display_error, assigns.error || database_error(assigns.db_info))

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <h1>MAC Database</h1>
      <p class="text-on-surface-variant">
        Manage the OUI manufacturer database for MAC address lookups
      </p>
      <div class="management-actions">
        <button id="mac-database-refresh" phx-click="refresh" class="btn btn-ghost btn-sm">Refresh</button>
      </div>
      <.card title="Update Database">
        <p class="management-help">
          Local configured-file reload is available. Downloads and queued MAC/OUI sync jobs are not migrated; durable task storage authorization is pending. No download is queued and no task history is fabricated.
        </p>
        <div class="management-actions">
          <button class="btn btn-primary" disabled aria-disabled="true">Queue MAC/OUI sync</button>
          <button class="btn btn-ghost" disabled aria-disabled="true">MAC/OUI sync</button>
          <button
            id="mac-database-reload"
            phx-click="reload"
            class="btn btn-ghost"
            disabled={
              @reloading || is_nil(@db_info) || !@db_info.configured || @db_info.status == :loading
            }
          >Reload from Disk</button>
        </div>
        <p :if={@reloading} id="mac-database-operation" role="status">
          Reloading the configured MAC database file...
        </p>
      </.card>
      <p :if={@display_error} id="mac-database-error" class="alert alert-error" role="alert">
        {@display_error}
      </p>
      <.card title="Database Status">
        <p class="management-help">
          File size and modification time describe the last successfully loaded artifact;
          an invalid replacement on disk may differ.
        </p>
        <section
          :if={@db_info}
          id="mac-database-status"
          data-source={@db_info.source}
          data-status={@db_info.status}
          data-entry-count={@db_info.entry_count}
        >
          <dl>
            <dt>Status</dt><dd>{@db_info.status}</dd>
            <dt>Source</dt><dd>
              <span class={source_class(@db_info.source)}>{source_label(@db_info.source)}</span> {if @db_info.source ==
                                                                                                       :compiled,
                                                                                                     do:
                                                                                                       "Built-in (gsmlg_mac)",
                                                                                                     else:
                                                                                                       "Configured manuf file"}
            </dd>
            <dt>Entries</dt><dd>{@db_info.entry_count}</dd>
            <dt>Loaded At</dt><dd>{datetime(@db_info.loaded_at)}</dd>
            <dt>Configured</dt><dd>{if @db_info.configured, do: "Yes", else: "No"}</dd>
            <dt>File Size</dt><dd>{file_size(@db_info.file_info)}</dd>
            <dt>File Modified</dt><dd>{file_mtime(@db_info.file_info)}</dd>
            <dt>File Path</dt><dd class="font-mono break-all">
              {@db_info.path || "— (no file configured)"}
            </dd>
          </dl>
        </section>
        <p :if={is_nil(@db_info)} class="text-on-surface-variant">
          Database information unavailable.
        </p>
      </.card>
      <.card title="Test Lookup">
        <p class="text-on-surface-variant">Verify the database by looking up a MAC address.</p>
        <form id="mac-database-lookup-form" phx-submit="test_lookup" class="management-actions">
          <input
            type="text"
            name="mac"
            value={@query}
            aria-label="MAC address"
            placeholder="e.g. 00:00:0A:BB:28:FC"
            class="input"
            maxlength="256"
          />
          <button type="submit" class="btn btn-ghost" phx-disable-with="Looking up...">Lookup</button>
        </form>
        <div :if={@lookup_result} id="mac-database-lookup-result" class="alert alert-success">
          <div>
            <div class="font-bold">{@lookup_result.full}</div><div>{@lookup_result.short}</div>
          </div>
        </div>
        <div
          :if={@lookup_error}
          id="mac-database-lookup-error"
          class="alert alert-warning"
          role="alert"
        >
          {@lookup_error}
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
