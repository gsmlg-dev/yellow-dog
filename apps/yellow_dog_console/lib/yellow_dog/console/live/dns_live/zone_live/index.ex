defmodule YellowDog.Console.DnsLive.ZoneLive.Index do
  @moduledoc "Management-backed DNS zones for one selected Server and view."

  use YellowDog.Console, :live_view

  import YellowDog.Console.DnsLive.ManagementComponents, only: [input: 1]

  alias YellowDog.Console.DnsLive.ManagementComponents
  alias YellowDog.Console.DnsLive.ManagementSupport
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement

  @zone_form %{
    "view_name" => "default",
    "zone_name" => "",
    "zone_type" => "authoritative",
    "provider_id" => ""
  }

  @import_form %{
    "view_name" => "default",
    "zone_name" => "",
    "source_type" => "provider",
    "source_id" => "",
    "source_revision" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Zones",
       subscribed_server_id: nil,
       route_params: %{},
       view_name: "default",
       zones: [],
       providers: [],
       zone_form: to_form(@zone_form, as: "zone"),
       import_form: to_form(@import_form, as: "import"),
       selection_form: to_form(%{"view_name" => "default"}, as: "selection"),
       management_error: nil,
       operation_result: nil,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id} = params, _uri, socket) do
    view_name = params["view_name"] || "default"

    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign(
        route_params: params,
        view_name: view_name,
        zone_form: to_form(Map.put(@zone_form, "view_name", view_name), as: "zone"),
        import_form: to_form(Map.put(@import_form, "view_name", view_name), as: "import"),
        selection_form: to_form(%{"view_name" => view_name}, as: "selection")
      )

    socket = if connected?(socket), do: load_zones(socket, server_id), else: socket
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("select_view", %{"selection" => %{"view_name" => view_name}}, socket) do
    path = scoped_query_path(socket, :dns_zones, %{"view_name" => view_name})
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("create_zone", %{"zone" => params}, socket) do
    with :ok <- ManagementSupport.mutable(socket) do
      result =
        ServerManagement.dns_zones_create(
          ManagementSupport.selected_id(socket),
          zone_payload(socket, params),
          ManagementSupport.command_options(nil)
        )

      {:noreply,
       socket |> put_resource(result) |> ManagementSupport.finish(result, "Zone created")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("update_zone", %{"zone" => params}, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         {:ok, reference} <- edit_zone_reference(socket),
         {:ok, revision} <- zone_revision(socket.assigns.zones, reference) do
      payload = socket |> zone_payload(params) |> Map.merge(reference)

      result =
        ServerManagement.dns_zones_update(
          ManagementSupport.selected_id(socket),
          payload,
          ManagementSupport.command_options(revision)
        )

      {:noreply,
       socket
       |> put_resource(result, reference)
       |> ManagementSupport.finish(result, "Zone updated")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete_zone", params, socket) do
    reference = zone_reference(params)

    with :ok <- ManagementSupport.mutable(socket),
         {:ok, revision} <- zone_revision(socket.assigns.zones, reference) do
      result =
        ServerManagement.dns_zones_delete(
          ManagementSupport.selected_id(socket),
          reference,
          ManagementSupport.command_options(revision)
        )

      socket =
        if result.status == :ok,
          do:
            update(socket, :zones, &Enum.reject(&1, fn zone -> same_zone?(zone, reference) end)),
          else: socket

      {:noreply, ManagementSupport.finish(socket, result, "Zone deleted")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("sync_zone", params, socket) do
    reference = zone_reference(params)

    with :ok <- ManagementSupport.mutable(socket),
         {:ok, revision} <- zone_revision(socket.assigns.zones, reference) do
      payload = Map.put(reference, "provider_id", params["provider_id"])

      result =
        ServerManagement.dns_zones_sync(
          ManagementSupport.selected_id(socket),
          payload,
          ManagementSupport.command_options(revision)
        )

      message =
        case result do
          %ManagementResult{status: :ok, value: %{"changed_records" => count}} ->
            "Synchronized #{count} #{if count == 1, do: "record", else: "records"}"

          _result ->
            nil
        end

      {:noreply, ManagementSupport.finish(socket, result, message)}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("import_zone", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Zone import is unavailable because its revision is not exposed by the management API"
     )}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    socket =
      socket
      |> ManagementSupport.refresh_selected_server(server_id)
      |> load_zones(server_id)

    {:noreply, apply_action(socket, socket.assigns.live_action, socket.assigns.route_params)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def records_path(server_id, zone_name, view_name) do
    ServicePaths.server_path(server_id, {:dns_zone_records, zone_name}) <>
      "?" <> URI.encode_query(%{"view_name" => view_name})
  end

  def zone_path(server_id, destination, view_name) do
    ServicePaths.server_path(server_id, destination) <>
      "?" <> URI.encode_query(%{"view_name" => view_name})
  end

  defp scoped_query_path(socket, destination, query) do
    ServicePaths.server_path(ManagementSupport.selected_id(socket), destination) <>
      "?" <> URI.encode_query(query)
  end

  defp load_zones(socket, server_id) do
    zones_result =
      ServerManagement.dns_zones_list(server_id, %{"view_name" => socket.assigns.view_name})

    providers_result = ServerManagement.dns_providers_list(server_id)
    results = [zones_result, providers_result]

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — DNS Zones",
      zones: ManagementSupport.items(zones_result),
      providers: ManagementSupport.items(providers_result),
      management_error: ManagementSupport.first_error(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at),
      commands_enabled?: socket.assigns.service_online?
    )
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New DNS Zone",
      zone_form: to_form(Map.put(@zone_form, "view_name", socket.assigns.view_name), as: "zone")
    )
  end

  defp apply_action(socket, :edit, %{"zone_id" => zone_name}) do
    reference = %{"view_name" => socket.assigns.view_name, "zone_name" => zone_name}

    case Enum.find(socket.assigns.zones, &same_zone?(&1, reference)) do
      nil ->
        socket
        |> assign(
          :zone_form,
          to_form(Map.put(@zone_form, "view_name", socket.assigns.view_name), as: "zone")
        )
        |> put_flash(:error, "Zone is not present in the selected Server snapshot")

      zone ->
        assign(socket,
          page_title: "Edit DNS Zone",
          zone_form: to_form(zone_form_values(zone), as: "zone")
        )
    end
  end

  defp apply_action(socket, :import, _params) do
    assign(socket,
      page_title: "Import DNS Zone",
      import_form:
        to_form(Map.put(@import_form, "view_name", socket.assigns.view_name), as: "import")
    )
  end

  defp apply_action(socket, :index, _params), do: socket

  defp zone_form_values(zone) do
    %{
      "view_name" => zone["view_name"],
      "zone_name" => zone["zone_name"],
      "zone_type" => zone["zone_type"],
      "provider_id" => zone["provider_id"] || ""
    }
  end

  defp zone_payload(socket, params) do
    %{
      "view_name" => socket.assigns.view_name,
      "zone_name" => String.trim(params["zone_name"] || ""),
      "zone_type" => params["zone_type"] || "authoritative",
      "provider_id" => ManagementSupport.nullable(params["provider_id"])
    }
  end

  defp zone_reference(params) do
    %{"view_name" => params["view_name"], "zone_name" => params["zone_name"]}
  end

  defp zone_revision(zones, reference) do
    case ManagementSupport.find_digest(zones, &same_zone?(&1, reference)) do
      revision when is_binary(revision) -> {:ok, revision}
      _missing -> {:error, "Zone is not present in the selected Server snapshot"}
    end
  end

  defp same_zone?(zone, reference) do
    zone["view_name"] == reference["view_name"] and zone["zone_name"] == reference["zone_name"]
  end

  defp put_resource(socket, result), do: put_resource(socket, result, nil)

  defp put_resource(
         socket,
         %ManagementResult{status: :ok, value: %{"resource" => resource}},
         previous_reference
       ) do
    zones =
      [
        resource
        | Enum.reject(socket.assigns.zones, fn zone ->
            same_zone?(zone, resource) or
              (is_map(previous_reference) and same_zone?(zone, previous_reference))
          end)
      ]

    assign(socket, :zones, Enum.sort_by(zones, & &1["zone_name"]))
  end

  defp put_resource(socket, _result, _previous_reference), do: socket

  defp edit_zone_reference(socket) do
    case {socket.assigns.live_action, socket.assigns.route_params["zone_id"]} do
      {:edit, zone_name} when is_binary(zone_name) and zone_name != "" ->
        {:ok, %{"view_name" => socket.assigns.view_name, "zone_name" => zone_name}}

      _other ->
        {:error, "Zone update requires an edit route"}
    end
  end
end
