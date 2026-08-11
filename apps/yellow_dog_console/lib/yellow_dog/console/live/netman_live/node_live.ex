defmodule YellowDog.Console.NetmanLive.NodeLive do
  @moduledoc """
  Management-backed overview for one explicitly selected Netman runtime.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.NetmanManagement
  alias YellowDog.ManagementCore

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Netman",
       subscribed_netman_id: nil,
       capabilities: [],
       apply_mode: nil,
       reconciliation_health: %{},
       profiles: [],
       links: [],
       routes: [],
       vpn: nil,
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"netman_id" => netman_id}, _uri, socket) do
    socket = subscribe(socket, netman_id)
    {:noreply, if(connected?(socket), do: load_overview(socket, netman_id), else: socket)}
  end

  @impl true
  def handle_info({:netman_connection, _state, %{netman_id: netman_id}}, socket)
      when netman_id == socket.assigns.selected_netman.id do
    {:noreply, socket |> refresh_selected_netman(netman_id) |> load_overview(netman_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="netman-overview">
        <div class="flex items-center justify-between gap-4">
          <div>
            <div class="flex items-center gap-3">
              <.link navigate="/netman" class="btn btn-ghost btn-sm btn-circle">
                <.dm_mdi name="arrow-left" class="h-5 w-5" />
              </.link>
              <h1 class="text-4xl font-bold">{@selected_netman.name || @selected_netman.id}</h1>
              <.badge color={if @service_online?, do: "success", else: "ghost"} size="sm">
                {if @service_online?, do: "Connected", else: "Offline"}
              </.badge>
            </div>
            <p class="ml-10 mt-2 font-mono text-sm text-on-surface-variant">
              {@selected_netman.id}
            </p>
          </div>
        </div>

        <.offline_snapshot :if={not @service_online?} observed_at={@cached_observed_at} />
        <.management_error :if={@management_error} error={@management_error} />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-4">
          <.card>
            <div class="text-sm text-on-surface-variant">Apply mode</div>
            <div class="text-xl font-bold">{display(@apply_mode)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Reconciliation</div>
            <div class="text-xl font-bold">{display(@reconciliation_health["status"])}</div>
            <div class="text-xs text-on-surface-variant">
              {Map.get(@reconciliation_health, "pending_changes", 0)} pending
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Profiles</div>
            <div class="text-2xl font-bold text-info">{length(@profiles)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Links</div>
            <div class="text-2xl font-bold text-success">{length(@links)}</div>
          </.card>
        </div>

        <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <.card title="Profiles">
            <div :if={@profiles == []} class="text-sm text-on-surface-variant">
              No profiles reported
            </div>
            <div :for={state <- @profiles} class="flex items-center justify-between py-2">
              <div>
                <div class="font-semibold">{get_in(state, ["profile", "profile_id"])}</div>
                <div class="font-mono text-xs text-on-surface-variant">
                  {get_in(state, ["profile", "interface"]) || "any interface"}
                </div>
              </div>
              <.badge color={if state["active_revision"], do: "success", else: "ghost"} size="sm">
                {if state["active_revision"], do: "active", else: "desired"}
              </.badge>
            </div>
          </.card>

          <.card title="Network summary">
            <div :if={@links == []} class="text-sm text-on-surface-variant">No links reported</div>
            <div :for={link <- @links} class="flex items-center justify-between py-2">
              <span class="font-mono">{link["name"]}</span>
              <.badge color={if link["state"] == "up", do: "success", else: "ghost"} size="sm">
                {link["state"]}
              </.badge>
            </div>
            <div :for={route <- @routes} class="mt-2 text-sm text-on-surface-variant">
              <span class="font-mono">{route["destination"]}</span>
              via <span class="font-mono">{route["gateway"]}</span>
            </div>
          </.card>
        </div>

        <.card title="VPN profile state">
          <p class="text-sm text-on-surface-variant">
            VPN is configuration state only. Tunnel lifecycle controls are intentionally unavailable.
          </p>
          <div :if={@vpn} class="mt-3 flex items-center gap-3">
            <span class="font-semibold">{display(@vpn["profile_id"])}</span>
            <.badge color={if @vpn["state"] == "resolved", do: "success", else: "ghost"} size="sm">
              {display(@vpn["state"])}
            </.badge>
          </div>
        </.card>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-4">
          <.service_link
            id={@selected_netman.id}
            destination={:config}
            icon="tune"
            label="Configuration"
          />
          <.service_link
            id={@selected_netman.id}
            destination={:interfaces}
            icon="ethernet"
            label="Interfaces"
          />
          <.service_link id={@selected_netman.id} destination={:resolved} icon="dns" label="Resolved" />
          <.service_link
            id={@selected_netman.id}
            destination={:dhcp_client}
            icon="chip"
            label="DHCP Client"
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp service_link(assigns) do
    ~H"""
    <.link
      navigate={ServicePaths.netman_path(@id, @destination)}
      class="card bg-surface shadow-xl transition-shadow hover:shadow-2xl"
    >
      <div class="card-body items-center text-center">
        <.dm_mdi name={@icon} class="h-9 w-9 text-primary" />
        <h2 class="font-semibold">{@label}</h2>
      </div>
    </.link>
    """
  end

  defp offline_snapshot(assigns) do
    ~H"""
    <div class="alert alert-warning" id="offline-snapshot">
      <.dm_mdi name="cloud-off-outline" class="h-5 w-5" />
      <div>
        <div class="font-semibold">Offline cached snapshot</div>
        <div class="text-sm">Observed {format_observed_at(@observed_at)}</div>
      </div>
    </div>
    """
  end

  defp management_error(assigns) do
    ~H"""
    <div class="alert alert-error">
      <.dm_mdi name="alert-circle" class="h-5 w-5" />
      <span>{@error.message}</span>
    </div>
    """
  end

  defp load_overview(socket, netman_id) do
    results = [
      capabilities = NetmanManagement.runtime_capabilities_get(netman_id),
      apply_mode = NetmanManagement.runtime_apply_mode_get(netman_id),
      health = NetmanManagement.runtime_reconciliation_health_get(netman_id),
      profiles = NetmanManagement.profiles_list(netman_id),
      links = NetmanManagement.network_links_list(netman_id),
      routes = NetmanManagement.network_routes_list(netman_id),
      vpn = NetmanManagement.vpn_profile_get(netman_id)
    ]

    assign(socket,
      page_title: "#{socket.assigns.selected_netman.name || netman_id} — Network Manager",
      capabilities: value(capabilities, %{}) |> Map.get("capabilities", []),
      apply_mode: value(apply_mode, %{}) |> Map.get("mode"),
      reconciliation_health: value(health, %{}),
      profiles: items(profiles),
      links: items(links),
      routes: items(routes),
      vpn: value(vpn, nil),
      management_error: first_error(results),
      cached_observed_at: cached_observed_at(results, socket.assigns.selected_netman.last_seen_at)
    )
  end

  defp subscribe(socket, netman_id) do
    if connected?(socket) and socket.assigns.subscribed_netman_id != netman_id do
      if old_id = socket.assigns.subscribed_netman_id do
        Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "management:netman:#{old_id}")
      end

      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "management:netman:#{netman_id}")
    end

    assign(socket, :subscribed_netman_id, netman_id)
  end

  defp refresh_selected_netman(socket, netman_id) do
    case ManagementCore.get_netman(netman_id) do
      {:ok, netman} ->
        assign(socket,
          selected_netman: netman,
          service_online?: netman.status in [:online, "online"],
          snapshot_observed_at: netman.last_seen_at
        )

      _error ->
        socket
    end
  end

  defp value(%ManagementResult{status: :ok, value: value}, _default), do: value
  defp value(_result, default), do: default

  defp items(result), do: result |> value(%{}) |> Map.get("items", [])

  defp first_error(results) do
    Enum.find_value(results, fn
      %ManagementResult{status: :error} = result -> result
      _result -> nil
    end)
  end

  defp cached_observed_at(results, fallback) do
    Enum.find_value(results, fallback, fn
      %ManagementResult{source: :cache, observed_at: observed_at} -> observed_at
      _result -> nil
    end)
  end

  defp display(nil), do: "-"
  defp display(value) when is_atom(value), do: value |> Atom.to_string() |> display()
  defp display(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp display(value), do: to_string(value)

  defp format_observed_at(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  defp format_observed_at(value) when is_binary(value), do: value
  defp format_observed_at(_value), do: "unknown"
end
