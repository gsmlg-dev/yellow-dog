defmodule YellowDog.Console.MdnsLive.ServicesLive do
  @moduledoc "Management-backed mDNS service registry for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.MdnsLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Sync.Digest

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Registered mDNS Services",
       subscribed_server_id: nil,
       services: [],
       filter: :all,
       show_form: false,
       form_mode: :new,
       editing_service: nil,
       form_errors: %{},
       management_error: nil,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_services(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_services(socket)}

  def handle_event("filter", %{"filter" => filter}, socket) do
    filter = if filter in ["enabled", "disabled"], do: String.to_existing_atom(filter), else: :all
    {:noreply, assign(socket, :filter, filter)}
  end

  def handle_event("show_new_form", _params, socket) do
    {:noreply,
     assign(socket,
       show_form: true,
       form_mode: :new,
       editing_service: nil,
       form_errors: %{}
     )}
  end

  def handle_event("show_edit_form", %{"id" => service_id}, socket) do
    case find_service(socket.assigns.services, service_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Service not found")}

      service ->
        {:noreply,
         assign(socket,
           show_form: true,
           form_mode: :edit,
           editing_service: service,
           form_errors: %{}
         )}
    end
  end

  def handle_event("hide_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing_service: nil, form_errors: %{})}
  end

  def handle_event("validate_service", params, socket) do
    {:noreply, assign(socket, :form_errors, validate_service_params(params))}
  end

  def handle_event("save_service", params, socket) do
    with :ok <- mutable(socket),
         errors when map_size(errors) == 0 <- validate_service_params(params),
         {:ok, payload} <- service_payload(params, socket.assigns.editing_service) do
      result = save_service(socket, payload)

      case result do
        %ManagementResult{status: :ok, value: %{"resource" => service}} ->
          message =
            if socket.assigns.form_mode == :new, do: "Service registered", else: "Service updated"

          {:noreply,
           socket
           |> assign(
             services: put_service(socket.assigns.services, service),
             show_form: false,
             editing_service: nil,
             form_errors: %{}
           )
           |> put_flash(:info, message)}

        %ManagementResult{status: :error, message: message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      errors when is_map(errors) ->
        {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  def handle_event("toggle_service", %{"id" => service_id}, socket) do
    mutate_existing(socket, service_id, fn service, revision ->
      enabled = not service["enabled"]

      result =
        ServerManagement.mdns_services_toggle(
          socket.assigns.selected_server.id,
          %{"service_id" => service_id, "enabled" => enabled},
          expected_revision: revision,
          idempotency_key: Ecto.UUID.generate()
        )

      {result, if(enabled, do: "Service enabled", else: "Service disabled")}
    end)
  end

  def handle_event("delete_service", %{"id" => service_id}, socket) do
    mutate_existing(socket, service_id, fn _service, revision ->
      result =
        ServerManagement.mdns_services_delete(
          socket.assigns.selected_server.id,
          %{"service_id" => service_id},
          expected_revision: revision,
          idempotency_key: Ecto.UUID.generate()
        )

      {result, "Service deleted"}
    end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_services()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @doc false
  def validate_service_params(params) when is_map(params) do
    %{}
    |> require_value(:name, params["name"], "Service name is required")
    |> validate_type(params["type"])
    |> validate_port(params["port"])
    |> validate_txt(params["txt"])
  end

  def validate_service_params(_params), do: %{form: "Invalid service data"}

  defp load_services(socket) do
    result = ServerManagement.mdns_services_list(socket.assigns.selected_server.id)

    case result do
      %ManagementResult{status: :ok, value: %{"items" => services}} when is_list(services) ->
        assign(socket,
          services: services,
          management_error: nil,
          cached_observed_at: result.observed_at,
          commands_enabled?: socket.assigns.service_online?
        )

      %ManagementResult{status: :error} ->
        assign(socket,
          services: [],
          management_error: result,
          cached_observed_at: result.observed_at,
          commands_enabled?: false
        )
    end
  end

  defp save_service(socket, payload) do
    opts = [idempotency_key: Ecto.UUID.generate()]

    case socket.assigns.form_mode do
      :new ->
        ServerManagement.mdns_services_register(socket.assigns.selected_server.id, payload, opts)

      :edit ->
        opts = Keyword.put(opts, :expected_revision, revision(socket.assigns.editing_service))
        ServerManagement.mdns_services_update(socket.assigns.selected_server.id, payload, opts)
    end
  end

  defp mutate_existing(socket, service_id, callback) do
    with :ok <- mutable(socket),
         service when not is_nil(service) <- find_service(socket.assigns.services, service_id),
         revision when is_binary(revision) <- revision(service) do
      {result, message} = callback.(service, revision)

      case result do
        %ManagementResult{status: :ok, value: %{"resource" => updated}} ->
          {:noreply,
           socket
           |> assign(:services, put_service(socket.assigns.services, updated))
           |> put_flash(:info, message)}

        %ManagementResult{status: :ok, value: %{"resource_ref" => %{"service_id" => deleted}}} ->
          {:noreply,
           socket
           |> assign(
             :services,
             Enum.reject(socket.assigns.services, &(&1["service_id"] == deleted))
           )
           |> put_flash(:info, message)}

        %ManagementResult{status: :error, message: error} ->
          {:noreply, put_flash(socket, :error, error)}
      end
    else
      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}

      nil ->
        {:noreply, put_flash(socket, :error, "Service not found")}

      _missing_revision ->
        {:noreply, put_flash(socket, :error, "Service revision is unavailable")}
    end
  end

  defp mutable(%{assigns: %{commands_enabled?: true}}), do: :ok
  defp mutable(_socket), do: {:error, "The selected Server is offline; commands are disabled"}

  defp service_payload(params, editing) do
    name = String.trim(params["name"] || "")
    type = String.trim(params["type"] || "")

    service_id =
      case editing do
        %{"service_id" => service_id} -> service_id
        _new -> "#{name}.#{type}.local"
      end

    {:ok,
     %{
       "service_id" => service_id,
       "name" => name,
       "service_type" => type,
       "service_port" => String.to_integer(params["port"]),
       "txt" => parse_txt(params["txt"] || "")
     }}
  rescue
    _error -> {:error, "Invalid service data"}
  end

  defp parse_txt(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(fn row ->
      [key, value] = String.split(row, "=", parts: 2)
      %{"key" => String.trim(key), "value" => String.trim(value)}
    end)
    |> Enum.sort_by(& &1["key"])
  end

  defp revision(service) do
    case Digest.calculate(service) do
      {:ok, revision} -> revision
      {:error, _error} -> nil
    end
  end

  defp find_service(services, service_id),
    do: Enum.find(services, &(&1["service_id"] == service_id))

  defp put_service(services, service) do
    services
    |> Enum.reject(&(&1["service_id"] == service["service_id"]))
    |> Kernel.++([service])
    |> Enum.sort_by(& &1["service_id"])
  end

  defp filtered_services(services, :enabled), do: Enum.filter(services, & &1["enabled"])
  defp filtered_services(services, :disabled), do: Enum.reject(services, & &1["enabled"])
  defp filtered_services(services, _filter), do: services

  defp require_value(errors, key, value, message) do
    if is_binary(value) and String.trim(value) != "",
      do: errors,
      else: Map.put(errors, key, message)
  end

  defp validate_type(errors, value) do
    if is_binary(value) and Regex.match?(~r/^_[a-zA-Z0-9-]+\._(?:tcp|udp)$/, value) do
      errors
    else
      Map.put(errors, :type, "Must be _service._tcp or _service._udp format")
    end
  end

  defp validate_port(errors, value) do
    case Integer.parse(to_string(value || "")) do
      {port, ""} when port in 1..65_535 -> errors
      _invalid -> Map.put(errors, :port, "Port must be a number between 1 and 65535")
    end
  end

  defp validate_txt(errors, value) do
    valid? =
      value
      |> to_string()
      |> String.split("\n", trim: true)
      |> Enum.all?(fn row ->
        case String.split(row, "=", parts: 2) do
          [key, _value] -> String.trim(key) != ""
          _invalid -> false
        end
      end)

    if valid?, do: errors, else: Map.put(errors, :txt, "TXT rows must use key=value")
  end

  defp txt_for_form(nil), do: ""

  defp txt_for_form(service) do
    service
    |> Map.get("txt", [])
    |> Enum.map_join("\n", &"#{&1["key"]}=#{&1["value"]}")
  end
end
