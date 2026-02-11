defmodule YellowDog.Console.ToolsLive.GeoipLive do
  @moduledoc """
  GeoIP lookup tool. Queries the local MMDB database for IP geolocation data.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts

  @impl true
  def mount(_params, _session, socket) do
    db_info = fetch_db_info()

    {:ok,
     assign(socket,
       page_title: "GeoIP Lookup",
       query: "",
       result: nil,
       error: nil,
       db_info: db_info
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-4xl">
        <h1 class="text-2xl font-bold mb-4">GeoIP Lookup</h1>

        <form phx-submit="lookup" class="flex gap-2 mb-6">
          <input
            type="text"
            name="ip"
            value={@query}
            placeholder="Enter IP address (e.g. 8.8.8.8)"
            class="input input-bordered flex-1"
            autofocus
          />
          <button type="submit" phx-disable-with="Looking up..." class="btn btn-primary">Lookup</button>
        </form>

        <div :if={@error} class="alert alert-error mb-4">
          <span>{@error}</span>
        </div>

        <div :if={!@result && !@error && @query == ""} class="text-center py-12 text-base-content/50">
          Enter an IP address to look up its geolocation
        </div>

        <div :if={@result} class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4 mb-6">
          <.geo_card label="Country" value={"#{@result[:country]} (#{@result[:country_code]})"} />
          <.geo_card label="City" value={@result[:city]} />
          <.geo_card label="Subdivision" value={@result[:subdivision]} />
          <.geo_card label="Continent" value={"#{@result[:continent]} (#{@result[:continent_code]})"} />
          <.geo_card label="Timezone" value={@result[:timezone]} />
          <.geo_card label="Postal Code" value={@result[:postal_code]} />
          <.geo_card
            label="Coordinates"
            value={format_coordinates(@result[:latitude], @result[:longitude])}
          />
        </div>

        <div :if={@db_info} class="card bg-base-200 mt-6">
          <div class="card-body">
            <h2 class="card-title text-sm">Database Info</h2>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-2 text-sm">
              <div>
                <span class="font-semibold">Type:</span>
                <span>{@db_info[:database_type]}</span>
              </div>
              <div>
                <span class="font-semibold">Build:</span>
                <span>{format_epoch(@db_info[:build_epoch])}</span>
              </div>
              <div>
                <span class="font-semibold">IP Version:</span>
                <span>{@db_info[:ip_version]}</span>
              </div>
              <div>
                <span class="font-semibold">Node Count:</span>
                <span>{@db_info[:node_count]}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp geo_card(assigns) do
    ~H"""
    <div class="stat bg-base-200 rounded-box">
      <div class="stat-title">{@label}</div>
      <div class="stat-value text-lg">{@value || "—"}</div>
    </div>
    """
  end

  @impl true
  def handle_event("lookup", %{"ip" => ip}, socket) do
    ip = String.trim(ip)

    if ip == "" do
      {:noreply, assign(socket, result: nil, error: nil, query: "")}
    else
      case GeoIpDb.lookup(ip) do
        {:ok, info} ->
          {:noreply, assign(socket, result: info, error: nil, query: ip)}

        {:error, reason} ->
          {:noreply, assign(socket, result: nil, error: format_error(reason), query: ip)}
      end
    end
  end

  defp fetch_db_info do
    case GeoIpDb.database_info(:city) do
      {:ok, info} -> info
      _ -> nil
    end
  end

  defp format_coordinates(nil, _), do: nil
  defp format_coordinates(_, nil), do: nil
  defp format_coordinates(lat, lon), do: "#{lat}, #{lon}"

  defp format_epoch(nil), do: "—"
  defp format_epoch(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_epoch(epoch) when is_integer(epoch),
    do: epoch |> DateTime.from_unix!() |> format_epoch()

  defp format_epoch(_), do: "—"

  defp format_error({:error, reason}), do: format_error(reason)
  defp format_error(:einval), do: "Invalid IP address format"
  defp format_error(:not_found), do: "IP address not found in database"
  defp format_error(reason), do: "Lookup failed: #{inspect(reason)}"
end
