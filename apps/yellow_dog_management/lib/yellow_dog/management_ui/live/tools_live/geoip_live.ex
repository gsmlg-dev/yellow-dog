defmodule YellowDog.ManagementUI.ToolsLive.GeoipLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.GeoIP

  @impl true
  def mount(_params, _session, socket) do
    server = Application.get_env(:yellow_dog_management, :geoip_server, GeoIP)

    {:ok,
     assign(socket,
       page_title: "IP Geo Lookup",
       geoip_server: server,
       query: "",
       type: "city",
       result: nil,
       error: nil,
       loading: false,
       databases: database_info(server)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <h1>IP Geo Lookup</h1>
      <form id="geoip-lookup-form" phx-submit="lookup" class="management-actions">
        <label class="management-field">
          IP Address
          <input
            type="text"
            name="ip"
            value={@query}
            placeholder="Enter IP address (e.g. 8.8.8.8)"
            class="input"
            maxlength="64"
            disabled={@loading}
            autofocus
          />
        </label>
        <label class="management-field">
          Database
          <select name="type" class="select" disabled={@loading}>
            <option value="city" selected={@type == "city"}>City</option>
            <option value="country" selected={@type == "country"}>Country</option>
          </select>
        </label>
        <button class="btn btn-primary" type="submit" disabled={@loading}>Lookup</button>
      </form>
      <p :if={@loading} role="status">Looking up...</p>
      <div :if={@error} id="geoip-lookup-error" class="alert alert-error" role="alert">
        {@error}
      </div>
      <p :if={!@result && !@error && !@loading} class="management-help">
        Enter an IP address to look up its geographic location using a configured local database.
      </p>
      <section :if={@result} id="geoip-lookup-result" class="card card-bordered">
        <div class="card-body">
          <h2>Location for {@query}</h2>
          <dl>
            <dt>Country</dt>
            <dd>{display(@result.country)} ({display(@result.country_code)})</dd>
            <dt>City</dt><dd>{display(@result.city)}</dd>
            <dt>Subdivision</dt><dd>{display(@result.subdivision)}</dd>
            <dt>Continent</dt>
            <dd>{display(@result.continent)} ({display(@result.continent_code)})</dd>
            <dt>Timezone</dt><dd>{display(@result.timezone)}</dd>
            <dt>Postal Code</dt><dd>{display(@result.postal_code)}</dd>
            <dt>Coordinates</dt><dd>{coordinates(@result)}</dd>
          </dl>
        </div>
      </section>
      <section id="geoip-database-info" class="card card-bordered">
        <div class="card-body">
          <h2>Database Info</h2>
          <p :if={@databases == []}>Database service unavailable</p>
          <div :for={database <- @databases}>
            <h3>{database.name}</h3>
            <dl>
              <dt>Status</dt><dd>{database.status}</dd>
              <dt>Type</dt><dd>{display(database.metadata[:database_type])}</dd>
              <dt>Build</dt><dd>{epoch(database.metadata[:build_epoch])}</dd>
              <dt>IP Version</dt><dd>{display(database.metadata[:ip_version])}</dd>
              <dt>Node Count</dt><dd>{display(database.metadata[:node_count])}</dd>
            </dl>
          </div>
          <.link navigate="/system/ip-database" class="btn btn-secondary">Manage IP databases</.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("lookup", %{"ip" => ip, "type" => type}, socket)
      when is_binary(ip) and type in ["city", "country"] do
    query = String.trim(ip)
    database_type = if type == "city", do: :city, else: :country
    server = socket.assigns.geoip_server
    socket = cancel_async(socket, :geoip_lookup)

    if query == "" do
      {:noreply, assign(socket, query: "", type: type, result: nil, error: nil, loading: false)}
    else
      {:noreply,
       socket
       |> assign(query: query, type: type, loading: true, result: nil, error: nil)
       |> start_async(:geoip_lookup, fn -> GeoIP.lookup(query, database_type, server) end)}
    end
  end

  def handle_event("lookup", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:geoip_lookup)
     |> assign(error: "Invalid database selection", result: nil, loading: false)}
  end

  @impl true
  def handle_async(:geoip_lookup, {:ok, {:ok, result}}, socket) do
    {:noreply,
     assign(socket,
       result: result,
       loading: false,
       error: nil,
       databases: database_info(socket.assigns.geoip_server)
     )}
  end

  def handle_async(:geoip_lookup, {:ok, {:error, reason}}, socket),
    do: lookup_error(socket, reason)

  def handle_async(:geoip_lookup, {:exit, reason}, socket), do: lookup_error(socket, reason)

  defp lookup_error(socket, reason) do
    {:noreply,
     assign(socket,
       result: nil,
       loading: false,
       error: error_message(reason),
       databases: database_info(socket.assigns.geoip_server)
     )}
  end

  defp database_info(server) do
    case GeoIP.info(server) do
      entries when is_list(entries) -> entries
      _error -> []
    end
  end

  defp error_message(:invalid_ip), do: "Invalid IP address format"
  defp error_message(:not_found), do: "IP address not found in database"

  defp error_message(:unconfigured),
    do: "Database is not configured. Set its GeoIP path at startup."

  defp error_message(:not_loaded), do: "Database is not loaded. Reload it from IP Database."
  defp error_message(:loading), do: "Database is loading. Try again shortly."
  defp error_message(:unavailable), do: "Database service unavailable"
  defp error_message(reason), do: "Lookup failed: #{inspect(reason)}"

  defp display(nil), do: "—"
  defp display(value), do: value
  defp coordinates(%{latitude: nil}), do: "—"
  defp coordinates(%{longitude: nil}), do: "—"
  defp coordinates(result), do: "#{result.latitude}, #{result.longitude}"

  defp epoch(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      _error -> "—"
    end
  end

  defp epoch(_value), do: "—"
end
