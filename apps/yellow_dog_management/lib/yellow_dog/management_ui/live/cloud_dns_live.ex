defmodule YellowDog.ManagementUI.CloudDnsLive do
  use YellowDog.ManagementUI, {:live_view, log: false}

  alias YellowDog.Management.CloudDns
  alias YellowDog.Management.CloudDns.Provider
  alias YellowDog.ManagementUI.CloudDnsForms

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Cloud DNS",
       selected: nil,
       review: nil,
       direction: nil,
       working: false,
       error: nil,
       mode: nil,
       modal: nil,
       zone_id: params["zone_id"]
     )
     |> refresh()}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{working: true}} = socket), do: {:noreply, socket}

  def handle_event("open_binding", %{"mode" => mode}, socket) when mode in ["import", "create"] do
    %{providers: providers, zones: zones} = socket.assigns
    zone = selected_zone(zones, socket.assigns.zone_id)

    if providers != [] and (mode == "import" or zones != []) do
      {:noreply,
       assign(socket, mode: mode, modal: CloudDnsForms.binding_form(mode, providers, zones, zone))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_modal", _, socket),
    do: {:noreply, assign(socket, modal: nil, mode: nil)}

  def handle_event("submit_modal", params, %{assigns: %{mode: mode, modal: modal}} = socket)
      when mode in ["import", "create"] and is_map(modal) and is_map(params) do
    params = Map.put(params, "mode", mode)

    params =
      case selected_zone(socket.assigns.zones, socket.assigns.zone_id) do
        %{id: id} -> Map.put(params, "zone_id", id)
        nil -> params
      end

    case CloudDns.add(socket.assigns.caller, params) do
      {:ok, binding} ->
        {:reply, %{}, socket |> assign(modal: nil, mode: nil) |> refresh() |> select(binding)}

      {:error, reason} ->
        {:reply, %{error: message(reason)}, socket}
    end
  end

  def handle_event("submit_modal", params, %{assigns: %{mode: :conflicts, modal: modal}} = socket)
      when is_map(modal) and is_map(params) do
    confirm(socket |> assign(modal: nil, mode: nil), params)
  end

  def handle_event("select", %{"id" => id}, socket) do
    binding = Enum.find(socket.assigns.bindings, &(&1.id == id))
    {:noreply, select(socket, binding)}
  end

  def handle_event(
        "create_remote",
        _,
        %{assigns: %{selected: %{id: id}, caller: caller}} = socket
      ),
      do: run(socket, :create, fn -> CloudDns.create_remote(caller, id) end)

  def handle_event("unlink", _, %{assigns: %{selected: %{id: id}, caller: caller}} = socket),
    do: run(socket, :unlink, fn -> CloudDns.unlink(caller, id) end)

  def handle_event(
        "preview",
        %{"direction" => mode},
        %{assigns: %{selected: %{id: id}, caller: caller}} = socket
      )
      when mode in ["pull", "push"] do
    direction = if mode == "pull", do: :pull, else: :push

    socket
    |> assign(review: nil, direction: direction)
    |> run(:preview, fn -> CloudDns.preview(caller, id, direction) end)
  end

  def handle_event("confirm", _, %{assigns: %{review: %{blocked?: false} = review}} = socket) do
    if Enum.any?(review.rows, &(&1.state == :conflict)) do
      {:noreply,
       assign(socket, modal: CloudDnsForms.conflicts_form(review.rows), mode: :conflicts)}
    else
      confirm(socket, %{})
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp confirm(socket, choices) do
    with %{
           selected: %{id: id},
           review: %{stamp: stamp, blocked?: false},
           direction: direction,
           caller: caller
         } <- socket.assigns do
      run(socket, direction, fn -> CloudDns.confirm(caller, id, direction, stamp, choices) end)
    else
      _ -> {:noreply, socket}
    end
  end

  defp run(socket, action, fun) do
    {:noreply, socket |> assign(working: true, error: nil) |> start_async(action, fun)}
  end

  @impl true
  def handle_async(:preview, {:ok, {:ok, review}}, socket),
    do: {:noreply, assign(socket, working: false, review: review)}

  def handle_async(action, {:ok, {:ok, result}}, socket) do
    binding = if action == :unlink, do: nil, else: result

    {:noreply,
     socket
     |> assign(working: false)
     |> refresh()
     |> select(binding)
     |> put_flash(:info, success(action))}
  end

  def handle_async(_action, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(working: false) |> show_error(reason)}

  def handle_async(_action, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(working: false) |> show_error(:operation_interrupted)}

  defp refresh(socket) do
    with {:ok, bindings} <- CloudDns.list(socket.assigns.caller),
         {:ok, zones} <- CloudDns.zones(socket.assigns.caller),
         {:ok, providers} <- CloudDns.providers(socket.assigns.caller) do
      bindings =
        case selected_zone(zones, socket.assigns.zone_id) do
          %{id: id} -> Enum.filter(bindings, &(&1.zone_id == id))
          nil -> bindings
        end

      assign(socket, bindings: bindings, zones: zones, providers: providers)
    else
      _ -> assign(socket, bindings: [], zones: [], providers: [])
    end
  end

  defp select(socket, binding),
    do: assign(socket, selected: binding, review: nil, direction: nil, error: nil)

  defp show_error(socket, reason), do: assign(socket, :error, message(reason))

  defp success(:create),
    do: "Cloud zone created. Review a push to send records from the confirmed local version."

  defp success(:pull), do: "Cloud records saved to the local zone draft."
  defp success(:push), do: "Cloud records verified after synchronization."
  defp success(:unlink), do: "Cloud zone unlinked."

  defp message(:remote_zone_exists),
    do: "A matching cloud zone already exists. Link it using Import cloud zone."

  defp message(:remote_zone_not_empty),
    do: "The cloud zone already contains records. Link it using Import cloud zone."

  defp message(:missing_credentials),
    do: "Credentials for this profile are missing from the Management environment."

  defp message(:provider_not_found), do: "Select a configured Cloud Provider."

  defp message(:invalid_remote_zone_id), do: "Enter a valid cloud zone ID."

  defp message(:invalid_account_id),
    do: "Configure a valid Cloudflare account ID in the credential profile."

  defp message(:pull_first),
    do: "Review a pull first. Cloud records or protected entries differ from the local zone."

  defp message(:confirm_local_version),
    do: "Confirm the current draft in the Zone Versions tab before pushing."

  defp message(:local_zone_not_found), do: "The local zone no longer exists."
  defp message(:zone_name_mismatch), do: "The local and cloud zone names differ."

  defp message(:stale_preview),
    do: "The local or cloud data changed. Preview the operation again."

  defp message(:resolve_conflicts), do: "Choose which side to keep for each conflict."

  defp message(:cloud_write_unverified),
    do:
      "The provider accepted a write, but the new records could not yet be verified. Review current records before retrying."

  defp message(:operation_interrupted),
    do: "The operation was interrupted. Refresh the cloud records before retrying."

  defp message({:invalid_cloud_record, name, type}),
    do: "Could not read #{name} #{type} as a local record."

  defp message(%Ecto.Changeset{}), do: "This zone binding already exists."
  defp message(%{message: message}), do: message

  defp message(_),
    do: "Cloud DNS operation failed. Check the zone ID, credentials and provider permissions."

  defp state(:local_change), do: "Local change"
  defp state(:cloud_change), do: "Cloud change"
  defp state(:conflict), do: "Conflict"
  defp state(:protected), do: "Protected"

  defp rrset(nil), do: "—"
  defp rrset(rrset), do: "TTL #{rrset.ttl} · #{Enum.join(rrset.values, ", ")}"

  defp selected_zone(zones, id), do: Enum.find(zones, &(&1.id == id))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app caller={@caller} flash={@flash} current_path={@current_path}>
      <h1>Cloud DNS</h1>
      <% scope = selected_zone(@zones, @zone_id) %>
      <.link navigate={if scope, do: "/management/zones/#{scope.id}/edit", else: "/management/zones"}>
        {if scope, do: scope.name, else: "Back to Zones"}
      </.link>

      <.card title="Link a cloud zone">
        <.link :if={@providers == []} navigate="/system/cloud-providers">Configure a Cloud Provider</.link>
        <div :if={@providers != []} class="management-actions">
          <button
            id="cloud-dns-import-binding"
            type="button"
            class="btn btn-outline"
            phx-click="open_binding"
            phx-value-mode="import"
            disabled={@working}
          >Import cloud zone</button>
          <button
            id="cloud-dns-create-binding"
            type="button"
            class="btn btn-outline"
            phx-click="open_binding"
            phx-value-mode="create"
            disabled={@working || @zones == []}
          >Create cloud zone from local zone</button>
        </div>
      </.card>

      <.card title="Bindings">
        <p :if={@bindings == []}>No cloud zones linked.</p>
        <div :for={binding <- @bindings} class="management-actions">
          <% zone = selected_zone(@zones, binding.zone_id) %>
          <button
            type="button"
            phx-click="select"
            phx-value-id={binding.id}
            disabled={@working}
            class="btn btn-outline"
          >
            {binding.provider.name} · {(zone && zone.name) || binding.remote_id || "Pending zone"}
          </button>
        </div>
      </.card>

      <p :if={@error} id="cloud-dns-error" role="alert" class="alert alert-error">{@error}</p>
      <p :if={@working} role="status">Contacting the DNS provider…</p>

      <.card :if={@selected} title={@selected.provider.name}>
        <% zone = selected_zone(@zones, @selected.zone_id) %>
        <p>{Provider.label(@selected.provider.kind)}</p>
        <p :if={@selected.remote_id}>Zone ID <code>{@selected.remote_id}</code></p>
        <.link :if={zone} navigate={"/management/zones/#{zone.id}/edit"}>{zone && zone.name}</.link>
        <p :if={@selected.synced_at}>
          Last verified sync {Calendar.strftime(@selected.synced_at, "%Y-%m-%d %H:%M UTC")}
        </p>
        <div class="management-actions">
          <button
            :if={is_nil(@selected.remote_id)}
            id="cloud-dns-create-remote"
            type="button"
            phx-click="create_remote"
            data-confirm="Create a new zone at this provider?"
            disabled={@working}
            class="btn btn-primary"
          >Create cloud zone</button>
          <button
            :if={@selected.remote_id}
            id="cloud-dns-preview-pull"
            type="button"
            phx-click="preview"
            phx-value-direction="pull"
            disabled={@working}
            class="btn btn-outline"
          >Preview pull</button>
          <button
            :if={@selected.remote_id && @selected.baseline}
            id="cloud-dns-preview-push"
            type="button"
            phx-click="preview"
            phx-value-direction="push"
            disabled={@working}
            class="btn btn-outline"
          >Preview push</button>
          <button
            type="button"
            phx-click="unlink"
            data-confirm="Remove this synchronization binding?"
            disabled={@working}
            class="btn btn-ghost"
          >Unlink</button>
        </div>
      </.card>

      <.card :if={@review} title={if(@direction == :pull, do: "Review pull", else: "Review push")}>
        <p>{@review.name}</p>
        <p :if={@review.initial?}>
          Confirming this import replaces editable records and apex authority records in the matching local zone draft.
        </p>
        <p :if={@review.blocked?} role="status">Review a pull before pushing these changes.</p>
        <div id="cloud-dns-review">
          <p :if={@review.rows == []}>No editable record differences.</p>
          <div :if={@review.rows != []} class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Name</th><th>Type</th><th>Local</th><th>Cloud</th><th>Status</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @review.rows}>
                  <td>{elem(row.key, 0)}</td><td>{elem(row.key, 1)}</td>
                  <td>{rrset(row.local)}</td><td>{rrset(row.remote)}</td><td>
                    {state(row.state)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <details :if={@review.protected != []}>
            <summary>Provider-owned or unsupported record sets</summary>
            <ul>
              <li :for={{name, type} <- @review.protected}>{name} {type}</li>
            </ul>
          </details>
          <button
            id="cloud-dns-confirm"
            type="button"
            phx-click="confirm"
            class="btn btn-primary"
            disabled={@working || @review.blocked?}
          >
            {if @direction == :pull, do: "Confirm pull", else: "Confirm push"}
          </button>
        </div>
      </.card>
      <CloudDnsForms.modal form={@modal} />
    </Layouts.app>
    """
  end
end
