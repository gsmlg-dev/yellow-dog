defmodule YellowDog.Console.NetmanLive.DhcpClientLive do
  @moduledoc """
  Management-backed DHCP client state for one selected Netman runtime.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.NetmanManagement
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DHCP Client",
       subscribed_netman_id: nil,
       apply_mode: nil,
       leases: [],
       fsms: %{},
       leases_revision: nil,
       management_error: nil,
       operation_result: nil,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"netman_id" => netman_id}, _uri, socket) do
    socket = subscribe(socket, netman_id)
    {:noreply, if(connected?(socket), do: load_dhcp(socket, netman_id), else: socket)}
  end

  @impl true
  def handle_event("inspect_fsm", params, socket) do
    connection = connection_ref(params)
    result = NetmanManagement.dhcp_client_fsm_get(selected_id(socket), connection)

    socket =
      case result do
        %ManagementResult{status: :ok, value: fsm} ->
          assign(socket, :fsms, Map.put(socket.assigns.fsms, connection_key(connection), fsm))

        _result ->
          socket
      end

    {:noreply, finish(socket, result, "FSM state refreshed")}
  end

  @impl true
  def handle_event("release_lease", params, socket) do
    payload = connection_ref(params)

    with :ok <- mutable(socket),
         {:ok, revision} <- lease_revision(socket.assigns.leases, payload) do
      result =
        NetmanManagement.dhcp_client_connections_release_lease(
          selected_id(socket),
          payload,
          expected_revision: revision,
          idempotency_key: Ecto.UUID.generate()
        )

      socket =
        case result do
          %ManagementResult{status: :ok} ->
            update(
              socket,
              :leases,
              &Enum.reject(&1, fn lease -> same_connection?(lease, payload) end)
            )

          _result ->
            socket
        end

      {:noreply, finish(socket, result, "Lease released")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:netman_connection, _state, %{netman_id: netman_id}}, socket)
      when netman_id == socket.assigns.selected_netman.id do
    {:noreply, socket |> refresh_selected_netman(netman_id) |> load_dhcp(netman_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="netman-dhcp-client">
        <div class="flex items-center gap-2">
          <.link
            navigate={ServicePaths.netman_path(@selected_netman.id, :overview)}
            class="btn btn-ghost btn-sm btn-circle"
          >
            <.dm_mdi name="arrow-left" class="h-5 w-5" />
          </.link>
          <div>
            <div class="flex items-center gap-3">
              <h1 class="text-4xl font-bold">DHCP Client</h1>
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
        <div :if={@apply_mode == "observe"} class="alert alert-warning">
          Observe mode is read-only. Lease release is disabled.
        </div>
        <div :if={@apply_mode == "observe_first"} class="alert alert-info">
          Lease release requires the observe-first policy gate.
        </div>
        <.operation_error :if={error_result?(@management_error)} result={@management_error} />
        <.operation_error :if={error_result?(@operation_result)} result={@operation_result} />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.card>
            <div class="text-sm text-on-surface-variant">Active leases</div>
            <div class="text-2xl font-bold text-success">{length(@leases)}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Bound FSMs</div>
            <div class="text-2xl font-bold text-info">
              {Enum.count(@fsms, fn {_ref, fsm} -> fsm["state"] == "bound" end)}
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Snapshot revision</div>
            <div class="truncate font-mono text-xs">{@leases_revision || "-"}</div>
          </.card>
        </div>

        <.card title="DHCP leases">
          <div :if={@leases == []} class="py-8 text-center text-on-surface-variant">
            <.dm_mdi name="lan-disconnect" class="mx-auto mb-3 h-12 w-12" />
            <p>No active DHCP leases</p>
          </div>
          <div :if={@leases != []} class="overflow-x-auto">
            <table class="table table-striped" id="netman-dhcp-leases">
              <thead>
                <tr>
                  <th>Profile</th>
                  <th>Interface</th>
                  <th>FSM</th>
                  <th>Address</th>
                  <th>Expires</th>
                  <th class="text-right">Action</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={lease <- @leases}>
                  <td class="font-semibold">{lease["profile_id"]}</td>
                  <td class="font-mono">{lease["interface"]}</td>
                  <td>
                    <div class="flex items-center gap-2">
                      <.badge color={fsm_color(fsm_for(@fsms, lease))} size="sm">
                        {display(fsm_for(@fsms, lease)["state"])}
                      </.badge>
                      <button
                        phx-click="inspect_fsm"
                        phx-value-profile_id={lease["profile_id"]}
                        phx-value-interface={lease["interface"]}
                        class="btn btn-ghost btn-xs"
                      >
                        Inspect
                      </button>
                    </div>
                  </td>
                  <td class="font-mono">{lease["address"]}</td>
                  <td>{lease["expires_at"]}</td>
                  <td class="text-right">
                    <button
                      phx-click="release_lease"
                      phx-value-profile_id={lease["profile_id"]}
                      phx-value-interface={lease["interface"]}
                      phx-value-expected_revision={lease["revision"]}
                      class="btn btn-warning btn-sm"
                      disabled={not @commands_enabled? or not revision_available?(lease["revision"])}
                    >
                      Release
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
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

  defp load_dhcp(socket, netman_id) do
    mode_result = NetmanManagement.runtime_apply_mode_get(netman_id)
    leases_result = NetmanManagement.dhcp_client_leases_list(netman_id)
    leases_value = value(leases_result, %{})
    leases = Map.get(leases_value, "items", [])
    results = [mode_result, leases_result]
    apply_mode = mode_result |> value(%{}) |> Map.get("mode")

    assign(socket,
      page_title: "#{socket.assigns.selected_netman.name || netman_id} — DHCP Client",
      apply_mode: apply_mode,
      leases: leases,
      fsms: %{},
      leases_revision: Map.get(leases_value, "revision"),
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

  defp finish(socket, %ManagementResult{status: :ok} = result, message) do
    socket
    |> assign(operation_result: result)
    |> put_flash(:info, message)
  end

  defp finish(socket, %ManagementResult{} = result, _message) do
    socket
    |> assign(operation_result: result)
    |> put_flash(:error, result.message)
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

  defp selected_id(socket), do: socket.assigns.selected_netman.id

  defp lease_revision(leases, payload) do
    leases
    |> Enum.find(&same_connection?(&1, payload))
    |> case do
      %{"revision" => revision} ->
        case Digest.validate(revision) do
          {:ok, revision} -> {:ok, revision}
          _error -> {:error, "The exact lease revision is unavailable"}
        end

      _lease ->
        {:error, "The exact lease revision is unavailable"}
    end
  end

  defp revision_available?(revision), do: match?({:ok, _revision}, Digest.validate(revision))

  defp connection_ref(value) do
    %{"profile_id" => value["profile_id"], "interface" => value["interface"]}
  end

  defp connection_key(value), do: {value["profile_id"], value["interface"]}
  defp same_connection?(left, right), do: connection_key(left) == connection_key(right)
  defp fsm_for(fsms, lease), do: Map.get(fsms, connection_key(lease), %{"state" => "unknown"})

  defp fsm_color(%{"state" => "bound"}), do: "success"
  defp fsm_color(%{"state" => state}) when state in ["renewing", "rebinding"], do: "warning"
  defp fsm_color(_fsm), do: "ghost"

  defp value(%ManagementResult{status: :ok, value: value}, _default), do: value
  defp value(_result, default), do: default

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

  defp display(nil), do: "-"
  defp display(value) when is_atom(value), do: value |> Atom.to_string() |> display()
  defp display(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp display(value), do: to_string(value)

  defp format_observed_at(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  defp format_observed_at(value) when is_binary(value), do: value
  defp format_observed_at(_value), do: "unknown"
end
