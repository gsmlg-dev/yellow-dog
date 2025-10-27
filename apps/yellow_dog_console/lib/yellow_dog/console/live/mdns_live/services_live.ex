defmodule YellowDog.Console.MdnsLive.ServicesLive do
  @moduledoc """
  LiveView for managing registered mDNS services.
  """
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:services")
    end

    {:ok,
     socket
     |> assign(:page_title, "Registered Services")
     |> assign(:services, list_services())
     |> assign(:filter, :all)
     |> assign(:show_form, false)
     |> assign(:form_mode, :new)
     |> assign(:editing_service, nil)}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    filter_atom = String.to_atom(filter)

    {:noreply,
     socket
     |> assign(:filter, filter_atom)
     |> assign(:services, list_services(filter: filter_atom))}
  end

  @impl true
  def handle_event("toggle_service", %{"id" => service_id}, socket) do
    case YellowDog.Mdns.toggle_service(service_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:services, list_services(filter: socket.assigns.filter))
         |> put_flash(:info, "Service toggled successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle service: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_service", %{"id" => service_id}, socket) do
    case YellowDog.Mdns.unregister_service(service_id, persist: true) do
      :ok ->
        {:noreply,
         socket
         |> assign(:services, list_services(filter: socket.assigns.filter))
         |> put_flash(:info, "Service deleted successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete service: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("show_new_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:form_mode, :new)
     |> assign(:editing_service, nil)}
  end

  @impl true
  def handle_event("show_edit_form", %{"id" => service_id}, socket) do
    service = YellowDog.Mdns.get_registered_service(service_id)

    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:form_mode, :edit)
     |> assign(:editing_service, service)}
  end

  @impl true
  def handle_event("hide_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_service, nil)}
  end

  @impl true
  def handle_event("save_service", params, socket) do
    service_def = %{
      name: params["name"],
      type: params["type"],
      port: String.to_integer(params["port"]),
      txt: parse_txt_records(params["txt"]),
      addresses: parse_addresses(params["addresses"]),
      enabled: params["enabled"] == "true"
    }

    result =
      case socket.assigns.form_mode do
        :new ->
          YellowDog.Mdns.register_service(service_def, persist: true)

        :edit ->
          YellowDog.Mdns.update_service(
            socket.assigns.editing_service.id,
            service_def,
            persist: true
          )
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:show_form, false)
         |> assign(:editing_service, nil)
         |> assign(:services, list_services(filter: socket.assigns.filter))
         |> put_flash(:info, "Service saved successfully")}

      :ok ->
        {:noreply,
         socket
         |> assign(:show_form, false)
         |> assign(:editing_service, nil)
         |> assign(:services, list_services(filter: socket.assigns.filter))
         |> put_flash(:info, "Service updated successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save service: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:service_registered, _service_id}, socket) do
    {:noreply, assign(socket, :services, list_services(filter: socket.assigns.filter))}
  end

  @impl true
  def handle_info({:service_unregistered, _service_id}, socket) do
    {:noreply, assign(socket, :services, list_services(filter: socket.assigns.filter))}
  end

  @impl true
  def handle_info({:service_updated, _service_id}, socket) do
    {:noreply, assign(socket, :services, list_services(filter: socket.assigns.filter))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
        <div>
          <h1 class="text-4xl font-bold">Registered Services</h1>
          <p class="mt-2 text-base-content/70">Manage your mDNS service registrations</p>
        </div>
        <button
          type="button"
          phx-click="show_new_form"
          class="btn btn-primary gap-2"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
          Register Service
        </button>
      </div>
      <!-- Filter Tabs -->
      <div role="tablist" class="tabs tabs-boxed w-fit">
        <button
          role="tab"
          phx-click="filter"
          phx-value-filter="all"
          class={["tab", @filter == :all && "tab-active"]}
        >
          All Services
        </button>
        <button
          role="tab"
          phx-click="filter"
          phx-value-filter="enabled"
          class={["tab", @filter == :enabled && "tab-active"]}
        >
          Enabled
        </button>
        <button
          role="tab"
          phx-click="filter"
          phx-value-filter="disabled"
          class={["tab", @filter == :disabled && "tab-active"]}
        >
          Disabled
        </button>
      </div>
      <!-- Services List -->
      <%= if Enum.empty?(@services) do %>
        <.card class="text-center py-12">
          <svg
            class="mx-auto h-16 w-16 text-base-content/30"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
            />
          </svg>
          <h3 class="mt-4 text-lg font-medium">No services found</h3>
          <p class="mt-2 text-base-content/70">Get started by registering your first mDNS service.</p>
          <div class="mt-6">
            <button type="button" phx-click="show_new_form" class="btn btn-primary gap-2">
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 4v16m8-8H4"
                />
              </svg>
              Register Service
            </button>
          </div>
        </.card>
      <% else %>
        <.card>
          <.table id="services-table" rows={@services} zebra hover>
            <:col :let={service} label="Service Name">
              <div class="flex items-center gap-2">
                <span class="font-semibold"><%= service.name %></span>
                <.badge :if={service.enabled} color="success" size="sm">Enabled</.badge>
                <.badge :if={!service.enabled} color="ghost" size="sm">Disabled</.badge>
              </div>
            </:col>
            <:col :let={service} label="Type">
              <code class="text-sm"><%= service.type %></code>
            </:col>
            <:col :let={service} label="Port">
              <.badge color="info"><%= service.port %></.badge>
            </:col>
            <:col :let={service} label="Domain">
              <span class="text-sm"><%= service.domain %></span>
            </:col>
            <:col :let={service} label="Source">
              <.badge :if={service.source == :file} color="secondary" size="sm">File</.badge>
              <.badge :if={service.source != :file} color="primary" size="sm">API</.badge>
            </:col>
            <:col :let={service} label="Status">
              <.status_indicator
                status={if service.enabled, do: "running", else: "stopped"}
                pulse={service.enabled}
              />
            </:col>
            <:action :let={service}>
              <div class="flex gap-1">
                <button
                  type="button"
                  phx-click="toggle_service"
                  phx-value-id={service.id}
                  class="btn btn-ghost btn-xs"
                  title={if service.enabled, do: "Disable", else: "Enable"}
                >
                  <%= if service.enabled do %>
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M10 9v6m4-6v6m7-3a9 9 0 11-18 0 9 9 0 0118 0z"
                      />
                    </svg>
                  <% else %>
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"
                      />
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                      />
                    </svg>
                  <% end %>
                </button>
                <button
                  type="button"
                  phx-click="show_edit_form"
                  phx-value-id={service.id}
                  class="btn btn-ghost btn-xs"
                  title="Edit"
                >
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
                    />
                  </svg>
                </button>
                <button
                  type="button"
                  phx-click="delete_service"
                  phx-value-id={service.id}
                  data-confirm="Are you sure you want to delete this service?"
                  class="btn btn-ghost btn-xs text-error"
                  title="Delete"
                >
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                    />
                  </svg>
                </button>
              </div>
            </:action>
          </.table>
        </.card>
      <% end %>

      <!-- Service Form Modal -->
      <dialog :if={@show_form} id="service-modal" class="modal modal-open">
        <div class="modal-box max-w-2xl">
          <h3 class="font-bold text-2xl mb-4">
            <%= if @form_mode == :new, do: "Register New Service", else: "Edit Service" %>
          </h3>

          <form phx-submit="save_service" class="space-y-4">
            <div class="form-control">
              <label class="label">
                <span class="label-text font-semibold">Service Name</span>
              </label>
              <input
                type="text"
                name="name"
                value={@editing_service && @editing_service.name}
                placeholder="My Service"
                required
                class="input input-bordered w-full"
              />
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text font-semibold">Service Type</span>
              </label>
              <input
                type="text"
                name="type"
                value={@editing_service && @editing_service.type}
                placeholder="_http._tcp"
                required
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Example: _http._tcp, _ssh._tcp, _printer._tcp</span>
              </label>
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text font-semibold">Port</span>
              </label>
              <input
                type="number"
                name="port"
                value={@editing_service && @editing_service.port}
                placeholder="8080"
                required
                class="input input-bordered w-full"
              />
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text font-semibold">TXT Records</span>
              </label>
              <textarea
                name="txt"
                rows="3"
                placeholder="version=1.0&#10;path=/api"
                class="textarea textarea-bordered w-full"
              ><%= if @editing_service && @editing_service.txt, do: format_txt_for_form(@editing_service.txt) %></textarea>
              <label class="label">
                <span class="label-text-alt">Enter key=value pairs, one per line</span>
              </label>
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text font-semibold">IP Addresses</span>
              </label>
              <textarea
                name="addresses"
                rows="2"
                placeholder="192.168.1.100&#10;192.168.1.101"
                class="textarea textarea-bordered w-full"
              ><%= if @editing_service && @editing_service.addresses, do: Enum.join(@editing_service.addresses, "\n") %></textarea>
              <label class="label">
                <span class="label-text-alt">Enter IP addresses, one per line</span>
              </label>
            </div>

            <div class="form-control">
              <label class="label cursor-pointer justify-start gap-3">
                <input
                  type="checkbox"
                  name="enabled"
                  value="true"
                  checked={!@editing_service || @editing_service.enabled}
                  class="checkbox checkbox-primary"
                />
                <span class="label-text font-semibold">Enable service</span>
              </label>
            </div>

            <div class="modal-action">
              <button type="button" phx-click="hide_form" class="btn btn-ghost">
                Cancel
              </button>
              <button type="submit" class="btn btn-primary">
                <%= if @form_mode == :new, do: "Register", else: "Save Changes" %>
              </button>
            </div>
          </form>
        </div>
        <form method="dialog" class="modal-backdrop">
          <button phx-click="hide_form">close</button>
        </form>
      </dialog>
    </div>
    """
  end

  defp list_services(opts \\ []) do
    try do
      YellowDog.Mdns.list_registered_services(opts)
    rescue
      _ -> []
    end
  end

  defp parse_txt_records(txt_string) when is_binary(txt_string) do
    txt_string
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> {String.trim(key), String.trim(value)}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp parse_txt_records(_), do: %{}

  defp parse_addresses(addresses_string) when is_binary(addresses_string) do
    addresses_string
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_addresses(_), do: []

  defp format_txt_for_form(txt_map) when is_map(txt_map) do
    txt_map
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("\n")
  end

  defp format_txt_for_form(_), do: ""
end
