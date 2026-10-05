defmodule YellowDog.ManagementUI.IpDatabaseLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Domain, GeoIP}

  @impl true
  def mount(_params, _session, socket) do
    server = Application.get_env(:yellow_dog_management, :geoip_server, GeoIP)

    socket =
      assign(socket,
        page_title: "IP Database",
        geoip_server: server,
        databases: [],
        operation: nil,
        download_result: nil,
        error: nil
      )

    {:ok, refresh(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <h1>IP Database</h1>
      <div class="management-actions">
        <button id="ip-database-refresh" class="btn btn-secondary" phx-click="refresh">Refresh</button>
        <.link navigate="/tool/geoip" class="btn btn-secondary">IP Geo Lookup</.link>
      </div>
      <p class="management-help">
        Synchronization tasks download, validate and select durable MMDB artifacts.
        Reload and unload below only affect the local Management lookup database.
      </p>
      <p :if={@operation} role="status">Reloading {@operation} database...</p>
      <p
        :if={@download_result}
        id="ip-database-download-result"
        data-job-id={@download_result["id"]}
        data-task-key={@download_result["task_key"]}
        role="status"
      >
        Task queued (job {@download_result["id"]}). Queueing is not successful completion.
      </p>
      <div :if={@error} id="ip-database-error" class="alert alert-error" role="alert">{@error}</div>
      <section
        :for={database <- @databases}
        id={"ip-database-#{database.name}"}
        class="card card-bordered"
      >
        <div class="card-body">
          <h2>{if database.name == :city, do: "City Database", else: "Country Database"}</h2>
          <dl>
            <dt>Status</dt><dd data-status={database.status}>{database.status}</dd>
            <dt>Loaded snapshot</dt><dd>{if database.loaded, do: "Available", else: "None"}</dd>
            <dt>Configured Path</dt><dd>{display(database.path)}</dd>
            <dt>SHA-256</dt><dd>{display(database.digest)}</dd>
            <dt>File Size</dt><dd>{file_size(database.file_size)}</dd>
            <dt>File Modified</dt><dd>{epoch(database.modified_at)}</dd>
            <dt>Loaded At</dt><dd>{display(database.loaded_at)}</dd>
            <dt>Database Type</dt><dd>{display(database.metadata[:database_type])}</dd>
            <dt>Build</dt><dd>{epoch(database.metadata[:build_epoch])}</dd>
            <dt>IP Version</dt><dd>{display(database.metadata[:ip_version])}</dd>
            <dt>Node Count</dt><dd>{display(database.metadata[:node_count])}</dd>
            <dt>Record Size</dt><dd>{display(database.metadata[:record_size])}</dd>
            <dt>Languages</dt><dd>{languages(database.metadata[:languages])}</dd>
            <dt>Description</dt><dd>{description(database.metadata[:description])}</dd>
          </dl>
          <p :if={database.last_error} class="alert alert-error" role="alert">
            Last load failed: {inspect(database.last_error)}. {if database.loaded,
              do: "The last valid snapshot is still available.",
              else: "No snapshot is loaded."}
          </p>
          <p :if={!database.configured} class="management-help">
            Run Download / Sync, or set {environment_variable(database.name)} before starting Management.
          </p>
          <div class="management-actions">
            <button
              id={"ip-database-download-#{database.name}"}
              class="btn btn-secondary"
              phx-click="download"
              phx-value-type={database.name}
              phx-disable-with="Queueing…"
            >Queue IP {if database.name == :city, do: "City", else: "Country"}</button>
            <.link navigate={"/system/tasks/ip_#{database.name}"} class="btn btn-secondary">Sync History</.link>
            <button
              id={"ip-database-reload-#{database.name}"}
              class="btn btn-primary"
              phx-click="reload"
              phx-value-type={database.name}
              disabled={!database.configured || database.status == :loading || @operation != nil}
            >Reload</button>
            <button
              id={"ip-database-unload-#{database.name}"}
              class="btn btn-secondary"
              phx-click="unload"
              phx-value-type={database.name}
              data-confirm="Unload this database from memory? The configured MMDB file remains on disk. Reload restores it."
              disabled={!database.loaded && database.status != :loading}
            >Unload</button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("download", %{"type" => type}, socket) when type in ["city", "country"] do
    case Domain.mutate("run_task", %{"key" => "ip_#{type}"}, "operator", Ecto.UUID.generate()) do
      {:ok, job} ->
        {:noreply, assign(socket, download_result: job, error: nil)}

      {:error, error} ->
        {:noreply,
         assign(socket, download_result: nil, error: error[:message] || error["message"])}
    end
  end

  def handle_event("reload", %{"type" => type}, socket) when type in ["city", "country"] do
    if socket.assigns.operation do
      {:noreply, socket}
    else
      server = socket.assigns.geoip_server
      database_type = if type == "city", do: :city, else: :country

      {:noreply,
       socket
       |> assign(operation: type, error: nil)
       |> start_async(:reload_database, fn -> GeoIP.reload(database_type, server) end)}
    end
  end

  def handle_event("unload", %{"type" => type}, socket) when type in ["city", "country"] do
    database_type = if type == "city", do: :city, else: :country
    result = GeoIP.unload(database_type, socket.assigns.geoip_server)
    socket = refresh(socket)
    {:noreply, assign(socket, error: operation_error(result))}
  end

  def handle_event(event, _params, socket) when event in ["reload", "unload", "download"] do
    {:noreply, assign(socket, download_result: nil, error: "Invalid database selection")}
  end

  @impl true
  def handle_async(:reload_database, {:ok, result}, socket) do
    {:noreply, socket |> refresh() |> assign(operation: nil, error: operation_error(result))}
  end

  def handle_async(:reload_database, {:exit, reason}, socket) do
    {:noreply,
     socket |> refresh() |> assign(operation: nil, error: "Reload failed: #{inspect(reason)}")}
  end

  defp refresh(socket) do
    case GeoIP.info(socket.assigns.geoip_server) do
      entries when is_list(entries) -> assign(socket, databases: entries, error: nil)
      _error -> assign(socket, databases: [], error: "Database service unavailable")
    end
  end

  defp operation_error(:ok), do: nil
  defp operation_error({:error, reason}), do: "Database operation failed: #{inspect(reason)}"
  defp display(nil), do: "—"
  defp display(value), do: to_string(value)
  defp file_size(nil), do: "—"
  defp file_size(value), do: "#{value} bytes"
  defp languages(values) when is_list(values), do: Enum.join(values, ", ")
  defp languages(_values), do: "—"
  defp description(value) when is_map(value), do: value["en"] || "—"
  defp description(_value), do: "—"
  defp environment_variable(:city), do: "YELLOW_DOG_MANAGEMENT_GEOIP_CITY_PATH"
  defp environment_variable(:country), do: "YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH"

  defp epoch(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      _error -> "—"
    end
  end

  defp epoch(_value), do: "—"
end
