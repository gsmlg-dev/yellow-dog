defmodule YellowDog.ManagementUI.ToolsLive.GeoipLive do
  use YellowDog.ManagementUI, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "IP Geo Lookup")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <h1>IP Geo Lookup</h1>
      <p id="geoip-lookup-unavailable" role="status">
        Geographic lookup is unavailable until Worker-backed diagnostics are implemented. Management synchronizes database artifacts; it does not perform ongoing Worker lookups.
      </p>
      <.link navigate="/system/ip-database" class="btn btn-secondary">Manage IP database artifacts</.link>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event(_event, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Worker-backed lookup is unavailable")}
end
