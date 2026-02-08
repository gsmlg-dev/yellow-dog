defmodule YellowDog.Console.MdnsLive.ServicesLive do
  @moduledoc """
  LiveView for managing registered mDNS services.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.StringHelper

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:services")
    end

    {:ok,
     assign(socket,
       page_title: "Registered Services",
       service_running: service_running?(YellowDog.Mdns),
       services: list_services(),
       filter: :all,
       show_form: false,
       form_mode: :new,
       editing_service: nil,
       form_errors: %{}
     )}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    filter_atom =
      case filter do
        "all" -> :all
        "enabled" -> :enabled
        "disabled" -> :disabled
        _ -> :all
      end

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
  def handle_event("validate_service", params, socket) do
    {:noreply, assign(socket, :form_errors, validate_service_params(params))}
  end

  @impl true
  def handle_event("show_new_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:form_mode, :new)
     |> assign(:editing_service, nil)
     |> assign(:form_errors, %{})}
  end

  @impl true
  def handle_event("show_edit_form", %{"id" => service_id}, socket) do
    service = YellowDog.Mdns.get_registered_service(service_id)

    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:form_mode, :edit)
     |> assign(:editing_service, service)
     |> assign(:form_errors, %{})}
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
    errors = validate_service_params(params)

    if map_size(errors) > 0 do
      {:noreply, assign(socket, :form_errors, errors)}
    else
      port = parse_port(params["port"])

      service_def = %{
        name: params["name"],
        type: params["type"],
        port: port,
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
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    services = socket.assigns.services
    csv = build_csv(services)
    filename = "mdns_services_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"

    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @service_refresh_events ~w(service_registered service_unregistered service_updated service_toggled)a

  @impl true
  def handle_info({event, _service_id}, socket) when event in @service_refresh_events do
    {:noreply, assign(socket, :services, list_services(filter: socket.assigns.filter))}
  end

  @doc false
  def validate_service_params(params) do
    errors = %{}

    errors =
      case String.trim(params["name"] || "") do
        "" -> Map.put(errors, :name, "Service name is required")
        _ -> errors
      end

    errors =
      case String.trim(params["type"] || "") do
        "" ->
          Map.put(errors, :type, "Service type is required")

        type ->
          if type =~ ~r/^_[a-zA-Z0-9\-]+\._(?:tcp|udp)$/ do
            errors
          else
            Map.put(errors, :type, "Must be _service._tcp or _service._udp format")
          end
      end

    errors =
      case parse_port(params["port"]) do
        nil -> Map.put(errors, :port, "Port must be a number between 1 and 65535")
        _ -> errors
      end

    errors =
      case String.trim(params["addresses"] || "") do
        "" ->
          errors

        addresses_str ->
          invalid =
            addresses_str
            |> StringHelper.split_and_trim("\n")
            |> Enum.reject(fn addr ->
              match?({:ok, _}, :inet.parse_address(String.to_charlist(addr)))
            end)

          if invalid == [] do
            errors
          else
            Map.put(errors, :addresses, "Invalid IP address: #{hd(invalid)}")
          end
      end

    errors
  end

  defp parse_port(nil), do: nil
  defp parse_port(""), do: nil

  defp parse_port(port_str) when is_binary(port_str) do
    case Integer.parse(String.trim(port_str)) do
      {port, ""} when port >= 1 and port <= 65535 -> port
      _ -> nil
    end
  end

  defp list_services(opts \\ []) do
    try do
      YellowDog.Mdns.list_registered_services(opts)
    catch
      _, _ -> []
    end
  end

  defp parse_txt_records(txt_string) when is_binary(txt_string) do
    txt_string
    |> StringHelper.split_and_trim("\n")
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
    |> StringHelper.split_and_trim("\n")
  end

  defp parse_addresses(_), do: []

  defp format_txt_for_form(txt_map) when is_map(txt_map) do
    Enum.map_join(txt_map, "\n", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp format_txt_for_form(_), do: ""

  defp build_csv(services) do
    header =
      "Service Name,Type,Port,Domain,Enabled,Source,IP Addresses,TXT Records\r\n"

    rows =
      Enum.map_join(services, "\r\n", fn service ->
        [
          csv_escape(service.name),
          csv_escape(service.type),
          csv_escape(to_string(service.port)),
          csv_escape(service.domain || "local"),
          csv_escape(to_string(service.enabled)),
          csv_escape(to_string(service.source)),
          csv_escape(format_addresses_for_csv(service.addresses)),
          csv_escape(format_txt_for_csv(service.txt))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
