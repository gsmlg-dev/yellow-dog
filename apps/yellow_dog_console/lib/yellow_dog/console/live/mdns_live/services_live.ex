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
  def handle_event("export_csv", _params, socket) do
    services = socket.assigns.services
    csv = build_csv(services)
    filename = "mdns_services_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"

    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
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
  def handle_info({:service_toggled, _service_id}, socket) do
    {:noreply, assign(socket, :services, list_services(filter: socket.assigns.filter))}
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

  defp csv_escape(str) do
    if String.contains?(str, [",", "\"", "\n"]) do
      "\"" <> String.replace(str, "\"", "\"\"") <> "\""
    else
      str
    end
  end

  defp format_addresses_for_csv(addresses) when is_list(addresses) do
    Enum.join(addresses, "; ")
  end

  defp format_addresses_for_csv(_), do: ""

  defp format_txt_for_csv(txt_map) when is_map(txt_map) do
    txt_map
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("; ")
  end

  defp format_txt_for_csv(_), do: ""
end
