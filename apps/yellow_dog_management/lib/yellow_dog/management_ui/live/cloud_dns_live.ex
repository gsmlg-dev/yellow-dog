defmodule YellowDog.ManagementUI.CloudDnsLive do
  use YellowDog.ManagementUI, {:live_view, log: false}

  alias YellowDog.Management.CloudDns
  alias YellowDog.Management.CloudDns.Provider
  alias YellowDog.Management.Domain
  alias YellowDog.ManagementUI.CloudDnsForms

  @impl true
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        selected: nil,
        review: nil,
        direction: nil,
        working: false,
        error: nil,
        mode: nil,
        modal: nil,
        import_provider: "",
        remote_zones: nil,
        remote_zone_names: %{},
        import_error: nil
      )

    case socket.assigns.live_action do
      :new ->
        {:ok,
         socket
         |> assign(page_title: "New DNS Zone", zone: nil)
         |> refresh()
         |> load_pending_zone_names()}

      :sync ->
        with {:ok, zone} <- Domain.get_zone(params["zone_id"]) do
          socket =
            socket
            |> assign(page_title: "Cloud Sync", zone: zone)
            |> refresh()

          bindings = socket.assigns.bindings
          selected = Enum.find(bindings, &(&1.id == params["binding_id"])) || List.first(bindings)

          {:ok, if(selected, do: select(socket, selected), else: back_to_zone(socket))}
        else
          {:error, error} ->
            {:ok,
             socket
             |> put_flash(:error, error.message)
             |> push_navigate(to: "/management/zones")}
        end
    end
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{working: true}} = socket), do: {:noreply, socket}

  def handle_event(
        "open_binding",
        %{"mode" => "import"},
        %{assigns: %{live_action: :new}} = socket
      ) do
    case socket.assigns.providers do
      [] ->
        {:noreply, socket}

      providers ->
        provider_id =
          case providers do
            [%{id: id}] -> id
            _ -> ""
          end

        {:noreply, socket |> assign(mode: :import, modal: nil) |> load_remote_zones(provider_id)}
    end
  end

  def handle_event(
        "open_binding",
        %{"mode" => "create"},
        %{assigns: %{live_action: :new}} = socket
      ) do
    %{providers: providers, zones: zones} = socket.assigns

    if providers != [] and zones != [] do
      {:noreply,
       assign(socket,
         mode: "create",
         modal: CloudDnsForms.create_binding_form(providers, zones)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_modal", _, %{assigns: %{mode: :import}} = socket),
    do: {:noreply, socket |> cancel_async(:remote_zones) |> assign(mode: nil)}

  def handle_event("close_modal", _, socket),
    do: {:noreply, assign(socket, modal: nil, mode: nil)}

  def handle_event(
        "select_import_provider",
        %{"provider_id" => id},
        %{assigns: %{mode: :import}} = socket
      ) do
    {:noreply, load_remote_zones(socket, id)}
  end

  def handle_event("retry_import_provider", _, %{assigns: %{mode: :import}} = socket) do
    {:noreply, load_remote_zones(socket, socket.assigns.import_provider)}
  end

  def handle_event("import_cloud_zone", params, %{assigns: %{mode: :import}} = socket) do
    with %{"provider_id" => id, "remote_id" => remote_id} <- params,
         %{import_provider: ^id, remote_zones: {:ok, zones}} <- socket.assigns,
         %{name: name} <- Enum.find(zones, &(&1.id == remote_id)),
         {:ok, binding} <- add_binding(socket, "import", params) do
      {:noreply, socket |> remember_zone_name(binding, name) |> binding_added(binding)}
    else
      {:error, reason} -> {:noreply, assign(socket, :import_error, message(reason))}
      _ -> {:noreply, assign(socket, :import_error, "Select a cloud zone for this provider.")}
    end
  end

  def handle_event("submit_modal", params, %{assigns: %{mode: "create", modal: modal}} = socket)
      when is_map(modal) and is_map(params) do
    case add_binding(socket, "create", params) do
      {:ok, binding} ->
        {:reply, %{}, binding_added(socket, binding)}

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

  defp add_binding(socket, mode, params) do
    fields = if mode == "import", do: ~w(provider_id remote_id), else: ~w(provider_id zone_id)
    CloudDns.add(socket.assigns.caller, Map.put(Map.take(params, fields), "mode", mode))
  end

  defp binding_added(socket, %{zone_id: id} = binding) when is_binary(id),
    do: push_navigate(socket, to: sync_path(binding))

  defp binding_added(socket, binding),
    do: socket |> assign(modal: nil, mode: nil) |> refresh() |> select(binding)

  defp load_remote_zones(socket, provider_id) do
    socket = cancel_async(socket, :remote_zones)

    if Enum.any?(socket.assigns.providers, &(&1.id == provider_id)) do
      caller = socket.assigns.caller

      socket
      |> assign(import_provider: provider_id, remote_zones: :loading, import_error: nil)
      |> start_async(:remote_zones, fn -> CloudDns.remote_zones(caller, provider_id) end)
    else
      assign(socket, import_provider: "", remote_zones: nil, import_error: nil)
    end
  end

  defp load_pending_zone_names(socket) do
    if connected?(socket) do
      caller = socket.assigns.caller

      socket.assigns.bindings
      |> Enum.group_by(& &1.provider_id, & &1.remote_id)
      |> Enum.reduce(socket, fn {provider_id, ids}, socket ->
        ids = MapSet.new(ids)

        start_async(socket, {:pending_zone_names, provider_id}, fn ->
          with {:ok, zones} <- CloudDns.remote_zones(caller, provider_id) do
            for zone <- zones, MapSet.member?(ids, zone.id), into: %{} do
              {{provider_id, zone.id}, zone.name}
            end
          end
        end)
      end)
    else
      socket
    end
  end

  defp remember_zone_name(socket, binding, name) do
    assign(
      socket,
      :remote_zone_names,
      Map.put(socket.assigns.remote_zone_names, {binding.provider_id, binding.remote_id}, name)
    )
  end

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
  def handle_async(
        :remote_zones,
        {:ok, result},
        %{assigns: %{mode: :import, remote_zones: :loading}} = socket
      ),
      do: {:noreply, assign(socket, :remote_zones, result)}

  def handle_async(
        :remote_zones,
        {:exit, _reason},
        %{assigns: %{mode: :import, remote_zones: :loading}} = socket
      ),
      do: {:noreply, assign(socket, :remote_zones, {:error, :operation_interrupted})}

  def handle_async(:remote_zones, _result, socket), do: {:noreply, socket}

  def handle_async({:pending_zone_names, _provider_id}, {:ok, names}, socket) when is_map(names),
    do:
      {:noreply,
       assign(socket, :remote_zone_names, Map.merge(names, socket.assigns.remote_zone_names))}

  def handle_async({:pending_zone_names, _provider_id}, _result, socket), do: {:noreply, socket}

  def handle_async(:preview, {:ok, {:ok, review}}, socket) do
    {:noreply,
     socket
     |> remember_zone_name(socket.assigns.selected, review.name)
     |> assign(working: false, review: review)}
  end

  def handle_async(:pull, {:ok, {:ok, binding}}, %{assigns: %{live_action: :new}} = socket) do
    {:noreply,
     socket |> put_flash(:info, success(:pull)) |> push_navigate(to: sync_path(binding))}
  end

  def handle_async(action, {:ok, {:ok, result}}, socket) do
    socket = socket |> assign(working: false) |> refresh() |> put_flash(:info, success(action))
    binding = if action == :unlink, do: List.first(socket.assigns.bindings), else: result

    if is_nil(binding) and socket.assigns.live_action == :sync,
      do: {:noreply, back_to_zone(socket)},
      else: {:noreply, select(socket, binding)}
  end

  def handle_async(_action, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(working: false) |> show_error(reason)}

  def handle_async(_action, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(working: false) |> show_error(:operation_interrupted)}

  defp refresh(%{assigns: %{live_action: :new}} = socket) do
    with {:ok, bindings} <- CloudDns.list(socket.assigns.caller, nil),
         {:ok, zones} <- CloudDns.zones(socket.assigns.caller),
         {:ok, providers} <- CloudDns.providers(socket.assigns.caller) do
      assign(socket, bindings: bindings, zones: zones, providers: providers)
    else
      _ -> assign(socket, bindings: [], zones: [], providers: [])
    end
  end

  defp refresh(%{assigns: %{zone: %{"id" => id}, caller: caller}} = socket) do
    bindings =
      case CloudDns.list(caller, id) do
        {:ok, bindings} -> bindings
        {:error, _} -> []
      end

    assign(socket, bindings: bindings, zones: [], providers: [])
  end

  defp sync_path(binding),
    do: "/management/zones/#{binding.zone_id}/sync?binding_id=#{binding.id}"

  defp back_to_zone(socket),
    do: push_navigate(socket, to: "/management/zones/#{socket.assigns.zone["id"]}/edit")

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
    do: "Configure credentials for this provider under System Configuration → Cloud Providers."

  defp message(:provider_not_found), do: "Select a configured Cloud Provider."

  defp message(:invalid_remote_zone_id), do: "Choose a valid cloud zone."

  defp message(:route53_access_denied),
    do: "Route 53 denied access. Check the credentials and permissions for this operation."

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
    do:
      "Cloud DNS operation failed. Check the configuration, credentials and provider permissions."

  defp zone_list_error({:error, reason})
       when reason in [:missing_credentials, :provider_not_found, :invalid_account_id],
       do: message(reason)

  defp zone_list_error({:error, _reason}),
    do: "Could not load cloud zones. Check the provider credentials and zone listing permissions."

  defp zone_list_error(_), do: nil

  defp state(:local_change), do: "Local change"
  defp state(:cloud_change), do: "Cloud change"
  defp state(:conflict), do: "Conflict"
  defp state(:protected), do: "Protected"

  defp rrset(nil), do: "—"
  defp rrset(rrset), do: "TTL #{rrset.ttl} · #{Enum.join(rrset.values, ", ")}"

  defp zone_name(binding, names, zone) do
    names[{binding.provider_id, binding.remote_id}] || (zone && zone["name"]) ||
      "Zone name unavailable"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app caller={@caller} flash={@flash} current_path={@current_path}>
      <h1>{if @zone, do: "#{@zone["name"]} · Cloud Sync", else: @page_title}</h1>
      <.link navigate={
        if @zone, do: "/management/zones/#{@zone["id"]}/edit", else: "/management/zones"
      }>
        {if @zone, do: "Back to Zone", else: "Back to Zones"}
      </.link>
      <CloudDnsForms.zone_type_links :if={@live_action == :new} cloud?={true} />

      <.card :if={@live_action == :new} title="Cloud-synced authoritative zone">
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

      <.card
        :if={length(@bindings) > 1 || (@live_action == :new && @bindings != [])}
        title={if @live_action == :new, do: "Pending imports", else: "Cloud Providers"}
      >
        <div :for={binding <- @bindings} class="management-actions">
          <button
            type="button"
            phx-click="select"
            phx-value-id={binding.id}
            disabled={@working}
            class="btn btn-outline"
          >
            {binding.provider.name} · {zone_name(binding, @remote_zone_names, @zone)}
          </button>
        </div>
      </.card>

      <p :if={@error} id="cloud-dns-error" role="alert" class="alert alert-error">{@error}</p>
      <p :if={@working} role="status">Contacting the DNS provider…</p>

      <.card :if={@selected} title={@selected.provider.name}>
        <p>{Provider.label(@selected.provider.kind)}</p>
        <p id="cloud-dns-zone-name">{zone_name(@selected, @remote_zone_names, @zone)}</p>
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
      <CloudDnsForms.import_modal
        :if={@mode == :import}
        providers={@providers}
        provider_id={@import_provider}
        remote_zones={@remote_zones}
        error={@import_error || zone_list_error(@remote_zones)}
      />
      <CloudDnsForms.modal form={@modal} />
    </Layouts.app>
    """
  end
end
