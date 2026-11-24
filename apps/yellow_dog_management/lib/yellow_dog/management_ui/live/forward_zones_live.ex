defmodule YellowDog.ManagementUI.ForwardZonesLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Access, ForwardZones}
  alias YellowDog.ManagementUI.CloudDnsForms

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Forwarding Zones",
       modal: nil,
       editing: nil,
       error: nil,
       zones: [],
       workers: [],
       worker_names: %{},
       can_edit?: Access.authorize(socket.assigns.caller, "data:write") == :ok
     )
     |> refresh()}
  end

  @impl true
  def handle_event("add_zone", _params, %{assigns: %{can_edit?: true}} = socket) do
    socket = refresh(socket)

    if socket.assigns.workers == [] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, modal: form(socket.assigns.workers, nil), editing: nil)}
    end
  end

  def handle_event("edit_zone", %{"id" => id}, %{assigns: %{can_edit?: true}} = socket) do
    socket = refresh(socket)

    case Enum.find(socket.assigns.zones, &(&1.id == id)) do
      nil -> {:noreply, socket}
      zone -> {:noreply, assign(socket, modal: form(socket.assigns.workers, zone), editing: zone)}
    end
  end

  def handle_event("close_modal", _params, socket),
    do: {:noreply, assign(socket, modal: nil, editing: nil)}

  def handle_event("submit_modal", params, %{assigns: %{modal: modal}} = socket)
      when is_map(modal) do
    %{caller: caller, editing: zone} = socket.assigns

    result =
      if zone,
        do: ForwardZones.update(caller, zone.id, zone.revision, params),
        else: ForwardZones.create(caller, params)

    case result do
      {:ok, _zone} ->
        {:reply, %{},
         socket
         |> assign(modal: nil, editing: nil)
         |> refresh()
         |> put_flash(:info, "Forwarding zone saved. Publish a target to apply it to a Worker.")}

      {:error, %{message: message}} ->
        {:reply, %{error: message}, socket}
    end
  end

  def handle_event("delete_zone", %{"id" => id, "revision" => revision}, socket)
      when is_binary(revision) do
    with {revision, ""} <- Integer.parse(revision),
         {:ok, :deleted} <- ForwardZones.delete(socket.assigns.caller, id, revision) do
      {:noreply,
       socket
       |> refresh()
       |> put_flash(:info, "Forwarding zone deleted. Publish a target to apply the change.")}
    else
      {:error, %{message: message}} -> {:noreply, socket |> refresh() |> assign(error: message)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp refresh(socket) do
    case ForwardZones.list(socket.assigns.caller) do
      {:ok, %{zones: zones, workers: workers}} ->
        assign(socket,
          zones: zones,
          workers: workers,
          worker_names: Map.new(workers, &{&1.id, &1.name}),
          error: nil
        )

      {:error, %{message: message}} ->
        assign(socket, :error, message)
    end
  end

  defp form(workers, zone) do
    properties = %{
      name: %{
        type: "string",
        title: "DNS suffix",
        description: "Use a suffix such as corp.example. or . to match all other names.",
        minLength: 1,
        maxLength: 254
      },
      forwarders: %{
        type: "array",
        title: "Upstreams",
        minItems: 1,
        maxItems: 8,
        items: %{
          type: "object",
          title: "Upstream",
          additionalProperties: false,
          required: ["address"],
          properties: %{
            address: %{type: "string", title: "IP address", minLength: 1, maxLength: 64},
            port: %{type: "integer", title: "Port", minimum: 1, maximum: 65_535, default: 53}
          }
        }
      },
      worker_ids: %{
        type: "array",
        title: "Registered Workers",
        minItems: 1,
        uniqueItems: true,
        items: %{type: "string", enum: Enum.map(workers, & &1.id)},
        "x-widget": "checkbox-group",
        "x-options": Enum.map(workers, &%{value: &1.id, label: "#{&1.name} · #{&1.id}"})
      }
    }

    initial =
      if zone do
        Map.take(zone, [:name, :forwarders, :worker_ids])
      else
        %{name: "", forwarders: [%{address: "", port: 53}], worker_ids: []}
      end

    %{
      id: "forward-zone-form-#{Ecto.UUID.generate()}",
      title: if(zone, do: "Edit forwarding zone", else: "Add forwarding zone"),
      schema: %{
        type: "object",
        additionalProperties: false,
        required: ["name", "forwarders", "worker_ids"],
        properties: properties
      },
      initial: initial
    }
  end

  defp endpoint(%{"address" => address, "port" => port}) do
    if String.contains?(address, ":"), do: "[#{address}]:#{port}", else: "#{address}:#{port}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app caller={@caller} flash={@flash} current_path={@current_path}>
      <h1>Forwarding Zones</h1>
      <p :if={@error} role="alert" class="alert alert-error">{@error}</p>
      <.card title="Configure query forwarding">
        <p :if={@can_edit? and @workers == []}>Register a Worker to add a forwarding zone.</p>
        <button
          :if={@can_edit? and @workers != []}
          id="add-forward-zone"
          type="button"
          class="btn btn-primary"
          phx-click="add_zone"
        >
          Add forwarding zone
        </button>
        <p :if={@zones == []}>No forwarding zones configured.</p>
        <table :if={@zones != []} class="table" id="forward-zones">
          <thead>
            <tr>
              <th scope="col">DNS suffix</th>
              <th scope="col">Upstreams</th>
              <th scope="col">Assigned Workers</th>
              <th :if={@can_edit?} scope="col">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={zone <- @zones} id={"forward-zone-#{zone.id}"}>
              <td>{zone.name}</td>
              <td>{Enum.map_join(zone.forwarders, ", ", &endpoint/1)}</td>
              <td>{Enum.map_join(zone.worker_ids, ", ", &Map.get(@worker_names, &1, &1))}</td>
              <td :if={@can_edit?}>
                <button
                  type="button"
                  class="btn btn-outline"
                  phx-click="edit_zone"
                  phx-value-id={zone.id}
                >
                  Edit
                </button>
                <button
                  type="button"
                  class="btn btn-outline"
                  phx-click="delete_zone"
                  phx-value-id={zone.id}
                  phx-value-revision={zone.revision}
                  data-confirm={"Delete the forwarding zone #{zone.name}?"}
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
      <CloudDnsForms.modal form={@modal} />
    </Layouts.app>
    """
  end
end
