defmodule YellowDog.Console.NetmanLive.InterfacesLive do
  @moduledoc """
  Management-backed links, addresses, routes, and connection controls for one Netman.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.NetmanManagement
  alias YellowDog.ManagementCore

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Interfaces",
       subscribed_netman_id: nil,
       apply_mode: nil,
       links: [],
       addresses: [],
       routes: [],
       profiles: [],
       connection_result: nil,
       management_error: nil,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"netman_id" => netman_id}, _uri, socket) do
    socket = subscribe(socket, netman_id)
    {:noreply, if(connected?(socket), do: load_interfaces(socket, netman_id), else: socket)}
  end

  @impl true
  def handle_event("connection_state", params, socket) do
    payload = connection_ref(params)
    result = NetmanManagement.network_connection_state_get(selected_id(socket), payload)

    {:noreply,
     socket
     |> assign(connection_result: result)
     |> finish_error(result)}
  end

  def handle_event("activate_connection", params, socket) do
    with :ok <- mutable(socket) do
      result =
        NetmanManagement.connections_activate(
          selected_id(socket),
          connection_ref(params),
          command_options(params)
        )

      {:noreply, finish(socket, result, "Connection activated")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("deactivate_connection", params, socket) do
    with :ok <- mutable(socket) do
      result =
        NetmanManagement.connections_deactivate(
          selected_id(socket),
          connection_ref(params),
          command_options(params)
        )

      {:noreply, finish(socket, result, "Connection deactivated")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:netman_connection, _state, %{netman_id: netman_id}}, socket)
      when netman_id == socket.assigns.selected_netman.id do
    {:noreply, socket |> refresh_selected_netman(netman_id) |> load_interfaces(netman_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="netman-interfaces">
        <div class="flex items-center gap-2">
          <.link
            navigate={ServicePaths.netman_path(@selected_netman.id, :overview)}
            class="btn btn-ghost btn-sm btn-circle"
          >
            <.dm_mdi name="arrow-left" class="h-5 w-5" />
          </.link>
          <div>
            <div class="flex items-center gap-3">
              <h1 class="text-4xl font-bold">Interfaces</h1>
              <.badge color={if @service_online?, do: "success", else: "ghost"} size="sm">
                {if @service_online?, do: "Connected", else: "Offline"}
              </.badge>
            </div>
            <p class="mt-1 text-on-surface-variant">
              {@selected_netman.name || @selected_netman.id} · Apply mode: {display(@apply_mode)}
            </p>
          </div>
        </div>

        <.offline_snapshot :if={not @service_online?} observed_at={@cached_observed_at} />
        <.operation_error :if={error_result?(@management_error)} result={@management_error} />
        <.operation_error :if={error_result?(@connection_result)} result={@connection_result} />

        <div :if={@apply_mode == "observe"} class="alert alert-warning">
          Observe mode is read-only. Connection actions are disabled.
        </div>
        <div :if={@apply_mode == "observe_first"} class="alert alert-info">
          Connection actions require the observe-first policy gate.
        </div>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.card>
            <div class="text-sm text-on-surface-variant">Links</div>
            <div class="text-2xl font-bold text-info">{length(@links)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Addresses</div>
            <div class="text-2xl font-bold text-success">{length(@addresses)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Routes</div>
            <div class="text-2xl font-bold text-primary">{length(@routes)}</div>
          </.card>
        </div>

        <div :if={@links == []} class="card bg-surface shadow-xl">
          <div class="card-body py-12 text-center text-on-surface-variant">
            <.dm_mdi name="ethernet-cable-off" class="mx-auto mb-3 h-14 w-14" />
            <p>No links reported</p>
          </div>
        </div>

        <div :for={link <- @links} class="card bg-surface shadow-xl" id={"link-#{link["link_id"]}"}>
          <div class="card-body space-y-4">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <.dm_mdi name="ethernet" class="h-6 w-6 text-info" />
                <div>
                  <h2 class="font-mono text-lg font-bold">{link["name"]}</h2>
                  <div class="text-xs text-on-surface-variant">{link["link_id"]}</div>
                </div>
              </div>
              <.badge color={if link["state"] == "up", do: "success", else: "ghost"} size="sm">
                {link["state"]}
              </.badge>
            </div>

            <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
              <div>
                <h3 class="mb-2 text-sm font-semibold text-on-surface-variant">Addresses</h3>
                <div
                  :if={addresses_for(@addresses, link) == []}
                  class="text-sm text-on-surface-variant"
                >
                  No addresses
                </div>
                <div
                  :for={address <- addresses_for(@addresses, link)}
                  class="flex justify-between py-1 text-sm"
                >
                  <span class="font-mono">{address["address"]}</span>
                  <.badge color="ghost" size="sm">{address["scope"]}</.badge>
                </div>
              </div>
              <div>
                <h3 class="mb-2 text-sm font-semibold text-on-surface-variant">Routes</h3>
                <div :if={routes_for(@routes, link) == []} class="text-sm text-on-surface-variant">
                  No routes
                </div>
                <div :for={route <- routes_for(@routes, link)} class="py-1 text-sm">
                  <span class="font-mono">{route["destination"]}</span>
                  via <span class="font-mono">{route["gateway"]}</span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <.card title="Profile connections">
          <div :if={@profiles == []} class="text-sm text-on-surface-variant">
            No profile connections available.
          </div>
          <div
            :for={state <- @profiles}
            class="flex flex-wrap items-center justify-between gap-3 border-b border-outline-variant py-3 last:border-0"
          >
            <div>
              <div class="font-semibold">{profile_id(state)}</div>
              <div class="font-mono text-xs text-on-surface-variant">
                {profile_interface(state) || "no concrete interface"}
              </div>
            </div>
            <div class="flex gap-2">
              <button
                phx-click="connection_state"
                phx-value-profile_id={profile_id(state)}
                phx-value-interface={profile_interface(state)}
                class="btn btn-ghost btn-sm"
                disabled={is_nil(profile_interface(state))}
              >
                State
              </button>
              <button
                phx-click="activate_connection"
                phx-value-profile_id={profile_id(state)}
                phx-value-interface={profile_interface(state)}
                phx-value-expected_revision={state["desired_revision"]}
                class="btn btn-success btn-sm"
                disabled={not @commands_enabled? or is_nil(profile_interface(state))}
              >
                Activate
              </button>
              <button
                phx-click="deactivate_connection"
                phx-value-profile_id={profile_id(state)}
                phx-value-interface={profile_interface(state)}
                phx-value-expected_revision={state["desired_revision"]}
                class="btn btn-warning btn-sm"
                disabled={not @commands_enabled? or is_nil(profile_interface(state))}
              >
                Deactivate
              </button>
            </div>
          </div>
        </.card>

        <.card :if={successful_result?(@connection_result)} title="Connection result">
          <dl class="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <div>
              <dt class="text-xs text-on-surface-variant">Profile</dt><dd>
                {@connection_result.value["profile_id"]}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-on-surface-variant">Interface</dt><dd class="font-mono">
                {@connection_result.value["interface"]}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-on-surface-variant">State</dt><dd>
                {display(@connection_result.value["state"])}
              </dd>
            </div>
          </dl>
        </.card>
      </div>
    </Layouts.app>
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

  defp operation_error(assigns) do
    ~H"""
    <div class="alert alert-error">
      <.dm_mdi name="alert-circle" class="h-5 w-5" />
      <span>{@result.message}</span>
    </div>
    """
  end

  defp load_interfaces(socket, netman_id) do
    mode_result = NetmanManagement.runtime_apply_mode_get(netman_id)
    links_result = NetmanManagement.network_links_list(netman_id)
    addresses_result = NetmanManagement.network_addresses_list(netman_id)
    routes_result = NetmanManagement.network_routes_list(netman_id)
    profiles_result = NetmanManagement.profiles_list(netman_id)
    results = [mode_result, links_result, addresses_result, routes_result, profiles_result]
    apply_mode = mode_result |> value(%{}) |> Map.get("mode")

    assign(socket,
      page_title: "#{socket.assigns.selected_netman.name || netman_id} — Interfaces",
      apply_mode: apply_mode,
      links: items(links_result),
      addresses: items(addresses_result),
      routes: items(routes_result),
      profiles: items(profiles_result),
      management_error: first_error(results),
      cached_observed_at:
        cached_observed_at(results, socket.assigns.selected_netman.last_seen_at),
      commands_enabled?: socket.assigns.service_online? and apply_mode != "observe"
    )
  end

  defp mutable(%{assigns: %{service_online?: false}}),
    do: {:error, "The selected Netman is offline; commands are disabled"}

  defp mutable(%{assigns: %{apply_mode: "observe"}}),
    do: {:error, "Observe mode is read-only"}

  defp mutable(_socket), do: :ok

  defp connection_ref(params) do
    %{"profile_id" => params["profile_id"], "interface" => params["interface"]}
  end

  defp command_options(params) do
    [
      expected_revision: nullable(params["expected_revision"]),
      idempotency_key: Ecto.UUID.generate()
    ]
  end

  defp finish(socket, %ManagementResult{status: :ok} = result, message) do
    socket
    |> assign(connection_result: result)
    |> put_flash(:info, message)
  end

  defp finish(socket, %ManagementResult{} = result, _message) do
    socket
    |> assign(connection_result: result)
    |> finish_error(result)
  end

  defp finish_error(socket, %ManagementResult{status: :error, message: message}),
    do: put_flash(socket, :error, message)

  defp finish_error(socket, _result), do: socket

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

  defp selected_id(socket), do: socket.assigns.selected_netman.id
  defp nullable(value) when value in [nil, ""], do: nil
  defp nullable(value), do: value
  defp profile_id(state), do: get_in(state, ["profile", "profile_id"])
  defp profile_interface(state), do: get_in(state, ["profile", "interface"])

  defp addresses_for(addresses, link),
    do: Enum.filter(addresses, &(&1["link_id"] == link["link_id"]))

  defp routes_for(routes, link), do: Enum.filter(routes, &(&1["link_id"] == link["link_id"]))

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

  defp error_result?(%ManagementResult{status: :error}), do: true
  defp error_result?(_result), do: false
  defp successful_result?(%ManagementResult{status: :ok}), do: true
  defp successful_result?(_result), do: false

  defp display(nil), do: "-"
  defp display(value) when is_atom(value), do: value |> Atom.to_string() |> display()
  defp display(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp display(value), do: to_string(value)

  defp format_observed_at(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  defp format_observed_at(value) when is_binary(value), do: value
  defp format_observed_at(_value), do: "unknown"
end
