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
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-3xl font-bold text-zinc-900">Registered Services</h1>
          <p class="mt-2 text-zinc-600">Manage your mDNS service registrations</p>
        </div>
        <button
          type="button"
          phx-click="show_new_form"
          class="inline-flex items-center px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
        >
          <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
          Register Service
        </button>
      </div>
      <!-- Filter Tabs -->
      <div class="border-b border-zinc-200">
        <nav class="flex space-x-8">
          <button
            phx-click="filter"
            phx-value-filter="all"
            class={[
              "py-4 px-1 border-b-2 font-medium text-sm",
              if(@filter == :all,
                do: "border-blue-500 text-blue-600",
                else: "border-transparent text-zinc-500 hover:text-zinc-700 hover:border-zinc-300"
              )
            ]}
          >
            All Services
          </button>
          <button
            phx-click="filter"
            phx-value-filter="enabled"
            class={[
              "py-4 px-1 border-b-2 font-medium text-sm",
              if(@filter == :enabled,
                do: "border-blue-500 text-blue-600",
                else: "border-transparent text-zinc-500 hover:text-zinc-700 hover:border-zinc-300"
              )
            ]}
          >
            Enabled
          </button>
          <button
            phx-click="filter"
            phx-value-filter="disabled"
            class={[
              "py-4 px-1 border-b-2 font-medium text-sm",
              if(@filter == :disabled,
                do: "border-blue-500 text-blue-600",
                else: "border-transparent text-zinc-500 hover:text-zinc-700 hover:border-zinc-300"
              )
            ]}
          >
            Disabled
          </button>
        </nav>
      </div>
      <!-- Services List -->
      <div class="space-y-4">
        <%= if Enum.empty?(@services) do %>
          <div class="bg-white rounded-lg shadow p-12 text-center">
            <svg
              class="mx-auto h-12 w-12 text-zinc-400"
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
            <h3 class="mt-2 text-sm font-medium text-zinc-900">No services</h3>
            <p class="mt-1 text-sm text-zinc-500">Get started by registering a new service.</p>
            <div class="mt-6">
              <button
                type="button"
                phx-click="show_new_form"
                class="inline-flex items-center px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700"
              >
                <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
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
          </div>
        <% else %>
          <div :for={service <- @services} class="bg-white rounded-lg shadow">
            <div class="p-6">
              <div class="flex items-start justify-between">
                <div class="flex-1">
                  <div class="flex items-center space-x-3">
                    <h3 class="text-lg font-medium text-zinc-900"><%= service.name %></h3>
                    <span class={[
                      "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
                      if(service.enabled,
                        do: "bg-green-100 text-green-800",
                        else: "bg-zinc-100 text-zinc-800"
                      )
                    ]}>
                      <%= if service.enabled, do: "Enabled", else: "Disabled" %>
                    </span>
                    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-800">
                      <%= if service.source == :file, do: "From File", else: "Registered" %>
                    </span>
                  </div>
                  <div class="mt-4 grid grid-cols-2 gap-4">
                    <div>
                      <p class="text-sm text-zinc-500">Service Type</p>
                      <p class="mt-1 text-sm font-medium text-zinc-900"><%= service.type %></p>
                    </div>
                    <div>
                      <p class="text-sm text-zinc-500">Port</p>
                      <p class="mt-1 text-sm font-medium text-zinc-900"><%= service.port %></p>
                    </div>
                    <div>
                      <p class="text-sm text-zinc-500">Domain</p>
                      <p class="mt-1 text-sm font-medium text-zinc-900"><%= service.domain %></p>
                    </div>
                    <div>
                      <p class="text-sm text-zinc-500">FQDN</p>
                      <p class="mt-1 text-sm font-medium text-zinc-900 truncate"><%= service.fqdn %></p>
                    </div>
                  </div>

                  <%= if service.txt && map_size(service.txt) > 0 do %>
                    <div class="mt-4">
                      <p class="text-sm text-zinc-500">TXT Records</p>
                      <div class="mt-2 flex flex-wrap gap-2">
                        <span
                          :for={{key, value} <- service.txt}
                          class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-zinc-100 text-zinc-800"
                        >
                          <%= key %>=<%= value %>
                        </span>
                      </div>
                    </div>
                  <% end %>

                  <%= if service.addresses && length(service.addresses) > 0 do %>
                    <div class="mt-4">
                      <p class="text-sm text-zinc-500">IP Addresses</p>
                      <div class="mt-2 flex flex-wrap gap-2">
                        <span
                          :for={addr <- service.addresses}
                          class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-purple-100 text-purple-800"
                        >
                          <%= addr %>
                        </span>
                      </div>
                    </div>
                  <% end %>
                </div>
                <!-- Actions -->
                <div class="ml-6 flex flex-col space-y-2">
                  <button
                    type="button"
                    phx-click="toggle_service"
                    phx-value-id={service.id}
                    class="inline-flex items-center px-3 py-1.5 border border-zinc-300 text-sm font-medium rounded text-zinc-700 bg-white hover:bg-zinc-50"
                  >
                    <%= if service.enabled, do: "Disable", else: "Enable" %>
                  </button>
                  <button
                    type="button"
                    phx-click="show_edit_form"
                    phx-value-id={service.id}
                    class="inline-flex items-center px-3 py-1.5 border border-zinc-300 text-sm font-medium rounded text-zinc-700 bg-white hover:bg-zinc-50"
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    phx-click="delete_service"
                    phx-value-id={service.id}
                    data-confirm="Are you sure you want to delete this service?"
                    class="inline-flex items-center px-3 py-1.5 border border-red-300 text-sm font-medium rounded text-red-700 bg-white hover:bg-red-50"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
      <!-- Service Form Modal -->
      <%= if @show_form do %>
        <div class="fixed inset-0 z-50 overflow-y-auto">
          <div class="flex items-center justify-center min-h-screen px-4">
            <!-- Backdrop -->
            <div
              class="fixed inset-0 bg-zinc-500 bg-opacity-75 transition-opacity"
              phx-click="hide_form"
            >
            </div>
            <!-- Modal -->
            <div class="relative bg-white rounded-lg shadow-xl max-w-2xl w-full">
              <div class="px-6 py-4 border-b border-zinc-200">
                <h3 class="text-lg font-medium text-zinc-900">
                  <%= if @form_mode == :new, do: "Register New Service", else: "Edit Service" %>
                </h3>
              </div>

              <form phx-submit="save_service" class="p-6 space-y-4">
                <div>
                  <label class="block text-sm font-medium text-zinc-700">Service Name</label>
                  <input
                    type="text"
                    name="name"
                    value={@editing_service && @editing_service.name}
                    required
                    class="mt-1 block w-full rounded-md border-zinc-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                  />
                </div>

                <div>
                  <label class="block text-sm font-medium text-zinc-700">Service Type</label>
                  <input
                    type="text"
                    name="type"
                    value={@editing_service && @editing_service.type}
                    placeholder="_http._tcp"
                    required
                    class="mt-1 block w-full rounded-md border-zinc-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                  />
                </div>

                <div>
                  <label class="block text-sm font-medium text-zinc-700">Port</label>
                  <input
                    type="number"
                    name="port"
                    value={@editing_service && @editing_service.port}
                    required
                    class="mt-1 block w-full rounded-md border-zinc-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                  />
                </div>

                <div>
                  <label class="block text-sm font-medium text-zinc-700">
                    TXT Records (key=value, one per line)
                  </label>
                  <textarea
                    name="txt"
                    rows="3"
                    placeholder="version=1.0&#10;path=/api"
                    class="mt-1 block w-full rounded-md border-zinc-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                  ><%= if @editing_service && @editing_service.txt, do: format_txt_for_form(@editing_service.txt) %></textarea>
                </div>

                <div>
                  <label class="block text-sm font-medium text-zinc-700">
                    IP Addresses (one per line)
                  </label>
                  <textarea
                    name="addresses"
                    rows="2"
                    placeholder="192.168.1.100&#10;192.168.1.101"
                    class="mt-1 block w-full rounded-md border-zinc-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                  ><%= if @editing_service && @editing_service.addresses, do: Enum.join(@editing_service.addresses, "\n") %></textarea>
                </div>

                <div class="flex items-center">
                  <input
                    type="checkbox"
                    name="enabled"
                    value="true"
                    checked={!@editing_service || @editing_service.enabled}
                    class="h-4 w-4 text-blue-600 focus:ring-blue-500 border-zinc-300 rounded"
                  />
                  <label class="ml-2 block text-sm text-zinc-900">
                    Enable service
                  </label>
                </div>

                <div class="flex items-center justify-end space-x-3 pt-4 border-t border-zinc-200">
                  <button
                    type="button"
                    phx-click="hide_form"
                    class="px-4 py-2 border border-zinc-300 rounded-md text-sm font-medium text-zinc-700 bg-white hover:bg-zinc-50"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-blue-600 hover:bg-blue-700"
                  >
                    <%= if @form_mode == :new, do: "Register", else: "Save Changes" %>
                  </button>
                </div>
              </form>
            </div>
          </div>
        </div>
      <% end %>
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
