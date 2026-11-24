defmodule YellowDog.ManagementUI.ResourceViewsLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{DnsViews, Domain}
  alias YellowDog.ManagementUI.{CloudDnsForms, DnsRulesText}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "DNS Views", editing: nil, form: nil) |> reload()}
  end

  @impl true
  def handle_event("new", _, socket), do: {:noreply, open(socket, nil)}

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.views, &(&1["id"] == id)) do
      nil -> {:noreply, socket}
      view -> {:noreply, open(socket, view)}
    end
  end

  def handle_event("close_modal", _, socket), do: {:noreply, close(socket)}

  def handle_event("submit_modal", params, %{assigns: %{form: form}} = socket)
      when is_map(form) and is_map(params) do
    with {:ok, raw} <- rule_text(params["client_rules"]),
         {:ok, rules} <- DnsRulesText.parse(raw),
         values = Map.put(params, "client_rules", rules),
         {:ok, _view} <-
           DnsViews.save_resource(socket.assigns.caller, changes(socket.assigns.editing, values)) do
      {:reply, %{}, socket |> close() |> reload() |> put_flash(:info, "DNS View saved")}
    else
      {:error, reason} -> {:reply, %{error: error(reason)}, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.views, &(&1["id"] == id)) do
      nil ->
        {:noreply, socket}

      view ->
        case DnsViews.delete_resource(socket.assigns.caller, id, view["revision"]) do
          {:ok, _view} ->
            {:noreply, socket |> close() |> reload() |> put_flash(:info, "DNS View deleted")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error(reason))}
        end
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp changes(nil, params), do: params

  defp changes(view, params) do
    Map.merge(params, %{"id" => view["id"], "expected_revision" => view["revision"]})
  end

  defp rule_text(lines) when is_list(lines) do
    if Enum.all?(lines, &is_binary/1),
      do: {:ok, Enum.join(lines, "\n")},
      else: {:error, {:rules, "Enter one rule per row"}}
  end

  defp rule_text(_), do: {:error, {:rules, "Enter one rule per row"}}

  defp close(socket), do: assign(socket, editing: nil, form: nil)

  defp reload(socket) do
    assign(socket, views: DnsViews.resources(), workers: Domain.list_workers())
  end

  defp open(%{assigns: %{workers: []}} = socket, _view), do: socket

  defp open(socket, view) do
    options =
      Enum.map(socket.assigns.workers, &%{value: &1["id"], label: "#{&1["name"]} · #{&1["id"]}"})

    fields = %{
      "name" => %{
        type: "string",
        title: "Name",
        minLength: 1,
        maxLength: 63,
        pattern: "^[A-Za-z0-9_-]+$"
      },
      "priority" => %{
        type: "integer",
        title: "Priority",
        minimum: 0,
        description: "Views with lower priorities are checked first."
      },
      "client_rules" => %{
        type: "array",
        title: "Client rules",
        description:
          "Rules are checked in order. Use allow any, deny any or allow networks 192.0.2.0/24.",
        items: %{type: "string", minLength: 1},
        maxItems: 128
      },
      "recursion_enabled" => %{type: "boolean", title: "Enable recursion", "x-widget": "switch"},
      "enabled" => %{type: "boolean", title: "Enable View", "x-widget": "switch"},
      "worker_ids" => %{
        type: "array",
        title: "Target Workers",
        items: %{type: "string", enum: Enum.map(options, & &1.value)},
        minItems: 1,
        uniqueItems: true,
        "x-widget": "checkbox-group",
        "x-options": options
      }
    }

    initial =
      (view ||
         %{
           "priority" => 100,
           "enabled" => true,
           "recursion_enabled" => false,
           "client_rules" => [%{"action" => "allow", "kind" => "any"}],
           "worker_ids" => []
         })
      |> Map.take(Map.keys(fields))
      |> Map.update!(
        "client_rules",
        &(&1 |> DnsRulesText.format() |> String.split("\n", trim: true))
      )

    form = %{
      id: "dns-view-modal-#{Ecto.UUID.generate()}",
      title: if(view, do: "Edit DNS View", else: "Add DNS View"),
      schema: %{
        type: "object",
        properties: fields,
        required: Map.keys(fields),
        additionalProperties: false
      },
      initial: initial
    }

    assign(socket, editing: view, form: form)
  end

  defp error(%{message: message}), do: message
  defp error({:rules, message}), do: message
  defp error(_), do: "The DNS View could not be saved."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app caller={@caller} flash={@flash} current_path={@current_path}>
      <h1>DNS Views</h1>
      <.card title="Views">
        <div class="management-actions">
          <button
            id="dns-view-new"
            type="button"
            class="btn btn-primary"
            phx-click="new"
            disabled={@workers == []}
          >Add DNS View</button>
        </div>
        <p :if={@workers == []}>Register a Worker to assign a View.</p>
        <p :if={@views == []}>No DNS Views configured.</p>
        <table :if={@views != []} id="dns-view-resources" class="table">
          <thead>
            <tr>
              <th>Name</th><th>Priority</th><th>Recursion</th><th>Workers</th><th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={view <- @views} id={"dns-view-#{view["id"]}"}>
              <td>{view["name"]} <span :if={not view["enabled"]}>Disabled</span></td>
              <td>{view["priority"]}</td>
              <td>{if view["recursion_enabled"], do: "Enabled", else: "Disabled"}</td>
              <td>
                {Enum.map_join(view["worker_ids"], ", ", fn id -> worker_name(@workers, id) end)}
              </td>
              <td>
                <button
                  type="button"
                  class="btn btn-outline"
                  phx-click="edit"
                  phx-value-id={view["id"]}
                >Edit</button>
                <button
                  type="button"
                  class="btn btn-ghost"
                  data-confirm="Delete this DNS View?"
                  phx-click="delete"
                  phx-value-id={view["id"]}
                >Delete</button>
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
      <CloudDnsForms.modal form={@form} />
    </Layouts.app>
    """
  end

  defp worker_name(workers, id) do
    Enum.find_value(workers, id, fn worker -> if worker["id"] == id, do: worker["name"] end)
  end
end
