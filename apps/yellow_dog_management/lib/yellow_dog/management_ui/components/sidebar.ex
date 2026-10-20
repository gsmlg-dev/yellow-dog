defmodule YellowDog.ManagementUI.Components.Sidebar do
  @moduledoc """
  Section navigation with a stable component and per-section scroll position.
  Selection comes from the route and existing page-provided records only.
  """
  use YellowDog.ManagementUI, :live_component

  alias YellowDog.ManagementUI.{Navigation, ServicePaths}

  @impl true
  def update(assigns, socket) do
    current_path = Map.get(assigns, :current_path)
    section = Navigation.section_for_path(current_path)
    scope = Map.get(assigns, :navigation_scope)
    target_type = if match?({:netman, _}, scope), do: :netman, else: :server
    records = valid_records(assigns, target_type)
    selected_record = selected_record(records, scope, target_type)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:section, section)
     |> assign(:sections, Navigation.sections())
     |> assign(:groups, Navigation.groups(section, scope, current_path))
     |> assign(:active_item, Navigation.item_for_path(current_path))
     |> assign(:scroll_key, "sidebar:#{section || :none}")
     |> assign(:target_type, target_type)
     |> assign(:records, records)
     |> assign(:selected_record, selected_record)}
  end

  @impl true
  def handle_event("select_server", %{"selection" => %{"id" => id}}, socket),
    do: navigate_to_selection(socket, :server, id)

  def handle_event("select_netman", %{"selection" => %{"id" => id}}, socket),
    do: navigate_to_selection(socket, :netman, id)

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="yd-sidebar yd-sidebar-sticky"
      data-scroll-key={@scroll_key}
      data-section={@section}
      phx-hook="PreserveScroll"
      role="navigation"
      aria-label="Section navigation"
      hidden={is_nil(@section)}
    >
      <button
        type="button"
        class="yd-sidebar-overlay"
        aria-label="Close menu"
        phx-click={close_menu()}
      ></button>
      <div class="yd-sidebar-panel">
        <nav aria-label="Mobile navigation" class="yd-mobile-navigation">
          <button type="button" class="btn btn-ghost" phx-click={close_menu()}>Close menu</button>
          <ul class="nested-menu p-4">
            <li :for={section <- @sections}>
              <.link
                navigate={section.path}
                data-section={section.id}
                class={@section == section.id && "active"}
                aria-current={@section == section.id && "page"}
                phx-click={close_menu()}
              >
                <.dm_mdi name={section.icon} width="20" height="20" />
                <span>{section.label}</span>
              </.link>
            </li>
          </ul>
        </nav>
        <ul
          id="app-sidebar-navigation"
          data-section={@section}
          class="nested-menu nested-menu-bordered p-4"
        >
          <.selection_control
            :if={@section in [:nodes, :data] && @navigation_scope != nil && @records != []}
            target_type={@target_type}
            myself={@myself}
            records={@records}
            selected_record={@selected_record}
          />
          <%= for group <- @groups do %>
            <li class="nested-menu-title">{group.label}</li>
            <li :for={item <- group.items}>
              <.link
                :if={item.status == :available}
                navigate={item.path}
                data-nav-item={item.id}
                class={@active_item == item.id && "active"}
                aria-current={@active_item == item.id && "page"}
                title={item.description}
                phx-click={close_menu()}
              >
                <.dm_mdi name={item.icon} width="20" height="20" />
                <span>{item.label}</span>
              </.link>
              <span
                :if={item.status != :available}
                data-nav-item={item.id}
                aria-disabled="true"
                title={item.description}
                aria-label={"#{item.label}: #{item.description}"}
              >
                <.dm_mdi name={item.icon} width="20" height="20" />
                <span>{item.label}</span>
                <span class="badge badge-ghost">
                  {if item.status == :planned, do: "Planned", else: "Requires scope"}
                </span>
              </span>
              <p :if={item.description} class="management-help">{item.description}</p>
            </li>
          <% end %>
        </ul>
      </div>
    </div>
    """
  end

  attr :target_type, :atom, required: true
  attr :myself, :any, required: true
  attr :records, :list, required: true
  attr :selected_record, :any, default: nil

  defp selection_control(assigns) do
    assigns =
      assigns
      |> assign(:id, "#{assigns.target_type}-selection-form")
      |> assign(:label, if(assigns.target_type == :server, do: "Worker", else: "Netman"))

    ~H"""
    <li class="nested-menu-title">Selected {@label}</li>
    <li>
      <form id={@id} phx-change={"select_#{@target_type}"} phx-target={@myself}>
        <label for={"#{@id}-select"} class="sr-only">Select {@label}</label>
        <select
          id={"#{@id}-select"}
          name="selection[id]"
          class="select select-sm w-full"
          aria-label={"Select #{@label}"}
        >
          <option value="" selected={is_nil(@selected_record)}>Select {@label}</option>
          <option
            :for={record <- @records}
            value={record.id}
            selected={selected_record?(@selected_record, record)}
          >
            {record_label(record)}
          </option>
        </select>
      </form>
    </li>
    """
  end

  defp valid_records(assigns, :server),
    do: Enum.filter(Map.get(assigns, :servers, []), &ServicePaths.valid_server_id?(&1.id))

  defp valid_records(assigns, :netman),
    do: Enum.filter(Map.get(assigns, :netmans, []), &ServicePaths.valid_netman_id?(&1.id))

  defp selected_record(records, {target_type, id}, target_type),
    do: Enum.find(records, &(&1.id == id))

  defp selected_record(_records, _scope, _target_type), do: nil

  defp navigate_to_selection(socket, target_type, ""),
    do: {:noreply, push_navigate(socket, to: selector_path(target_type))}

  defp navigate_to_selection(socket, target_type, id) do
    if socket.assigns.target_type == target_type &&
         Enum.any?(socket.assigns.records, &(&1.id == id)) do
      {:noreply, push_navigate(socket, to: selection_path(target_type, id))}
    else
      {:noreply, socket}
    end
  end

  defp selection_path(:server, id), do: ServicePaths.server_path(id, :dashboard)
  defp selection_path(:netman, id), do: ServicePaths.netman_path(id, :overview)
  defp selector_path(:server), do: "/server"
  defp selector_path(:netman), do: "/netman"
  defp selected_record?(%{id: id}, %{id: id}), do: true
  defp selected_record?(_selected_record, _record), do: false

  defp record_label(record) do
    name = Map.get(record, :name) || record.id
    "#{name} (#{Map.get(record, :status, :unknown)})"
  end

  defp close_menu do
    JS.remove_class("yd-sidebar-open", to: "#yd-layout")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#mobile-navigation-toggle")
  end
end
