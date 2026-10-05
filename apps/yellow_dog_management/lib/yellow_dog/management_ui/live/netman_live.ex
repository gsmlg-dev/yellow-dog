defmodule YellowDog.ManagementUI.NetmanLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.Domain
  alias YellowDog.ManagementUI.NetmansLive
  alias YellowDog.ManagementUI.Hooks.CurrentPath

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Netman", node: nil, scope_error: nil, netmans: [])}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, load(socket, CurrentPath.route_path_params(socket, uri)["netman_id"])}
  end

  @impl true
  def handle_event("change_metadata", %{"netman" => params}, socket)
      when is_map(params) and not is_nil(socket.assigns.node) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(NetmansLive.change_metadata(socket.assigns.form.params, params), as: "netman")
     )}
  end

  def handle_event("save_netman", %{"netman" => params}, socket)
      when is_map(params) and not is_nil(socket.assigns.node) do
    node = socket.assigns.node

    command =
      params
      |> NetmansLive.metadata_params()
      |> Map.merge(%{"id" => node["id"], "expected_revision" => node["revision"]})

    case Domain.mutate("update_netman", command, "operator", Ecto.UUID.generate()) do
      {:ok, _node} ->
        {:noreply,
         socket
         |> load(node["id"])
         |> put_flash(:info, "Desired metadata saved; no runtime activation.")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(
           :form,
           to_form(NetmansLive.change_metadata(socket.assigns.form.params, params), as: "netman")
         )
         |> put_flash(:error, NetmansLive.message(error))}
    end
  end

  def handle_event(_event, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Netman not found or invalid form")}

  defp load(socket, id) do
    socket = assign(socket, :netmans, Domain.list_netmans())

    if ServicePaths.valid_netman_id?(id) do
      case Domain.get_netman(id) do
        {:ok, node} ->
          assign(socket,
            node: node,
            scope_error: nil,
            page_title: node["name"],
            form: to_form(Map.take(node, ~w(name profile_name apply_mode features)), as: "netman")
          )

        {:error, error} ->
          assign(socket, node: nil, scope_error: NetmansLive.message(error))
      end
    else
      assign(socket, node: nil, scope_error: "Invalid Netman ID")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      netmans={Enum.map(@netmans, &%{id: &1["id"], name: &1["name"]})}
    >
      <div :if={@scope_error} id="netman-scope-error" role="alert">{@scope_error}</div>
      <div :if={@node} id="netman-overview" class="max-w-7xl space-y-6">
        <div>
          <h1 class="text-3xl font-bold">{@node["name"]}</h1><code>{@node["id"]}</code><p>
            Actual runtime state is unknown.
          </p>
        </div>
        <.card title="Logical Netman">
          <dl class="space-y-2">
            <dt>Status</dt><dd>{@node["status"]}</dd><dt>Actual State</dt><dd>
              {@node["actual_state"]}
            </dd>
            <dt>Last Seen</dt><dd>{@node["last_seen_at"] || "Never connected"}</dd>
            <dt>Metadata Revision</dt><dd>{@node["revision"]}</dd><dt>Registered At</dt><dd>
              {@node["registered_at"]}
            </dd><dt>Updated At</dt><dd>{@node["updated_at"]}</dd>
          </dl>
          <div class="flex flex-wrap gap-2 mt-4">
            <.link navigate={ServicePaths.netman_path(@node["id"], :config)} class="btn btn-primary">Configuration</.link>
            <.link
              navigate={ServicePaths.netman_path(@node["id"], :resolved)}
              class="btn btn-secondary"
            >Resolved</.link>
          </div>
          <p class="mt-4 text-on-surface-variant">
            Runtime activation, interfaces, routes and VPN are not migrated
          </p>
        </.card>
        <.card title="Desired Metadata">
          <NetmansLive.metadata_form form={@form} id="netman-edit-form" />
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
