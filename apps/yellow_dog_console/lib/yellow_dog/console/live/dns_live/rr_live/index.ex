defmodule YellowDog.Console.DnsLive.RrLive.Index do
  @moduledoc "Management-backed DNS records for one selected Server, view, and zone."

  use YellowDog.Console, :live_view

  import YellowDog.Console.DnsLive.ManagementComponents, only: [input: 1]

  alias YellowDog.Console.DnsLive.ManagementComponents
  alias YellowDog.Console.DnsLive.ManagementSupport
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement

  @form %{
    "record_id" => "",
    "name" => "@",
    "type" => "A",
    "ttl" => "300",
    "values" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Records",
       subscribed_server_id: nil,
       route_params: %{},
       view_name: "default",
       zone_name: nil,
       records: [],
       record_form: to_form(@form, as: "record"),
       management_error: nil,
       operation_result: nil,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id, "zone_id" => zone_name} = params, _uri, socket) do
    view_name = params["view_name"] || "default"

    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign(route_params: params, view_name: view_name, zone_name: zone_name)

    socket = if connected?(socket), do: load_records(socket, server_id), else: socket
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("create_record", %{"record" => params}, socket) do
    with :ok <- ManagementSupport.mutable(socket) do
      result =
        ServerManagement.dns_records_create(
          ManagementSupport.selected_id(socket),
          record_payload(socket, params),
          ManagementSupport.command_options(nil)
        )

      {:noreply,
       socket |> put_resource(result) |> ManagementSupport.finish(result, "Record created")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("update_record", %{"record" => params}, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         {:ok, record_id} <- edit_route_identity(socket),
         {:ok, revision} <- record_revision(socket.assigns.records, record_id) do
      payload = record_payload(socket, Map.put(params, "record_id", record_id))

      result =
        ServerManagement.dns_records_update(
          ManagementSupport.selected_id(socket),
          payload,
          ManagementSupport.command_options(revision)
        )

      {:noreply,
       socket
       |> put_resource(result, record_id)
       |> ManagementSupport.finish(result, "Record updated")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete_record", %{"record_id" => record_id}, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         {:ok, revision} <- record_revision(socket.assigns.records, record_id) do
      reference = record_reference(socket, record_id)

      result =
        ServerManagement.dns_records_delete(
          ManagementSupport.selected_id(socket),
          reference,
          ManagementSupport.command_options(revision)
        )

      socket =
        if result.status == :ok,
          do:
            update(
              socket,
              :records,
              &Enum.reject(&1, fn record -> record["record_id"] == record_id end)
            ),
          else: socket

      {:noreply, ManagementSupport.finish(socket, result, "Record deleted")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    socket =
      socket
      |> ManagementSupport.refresh_selected_server(server_id)
      |> load_records(server_id)

    {:noreply, apply_action(socket, socket.assigns.live_action, socket.assigns.route_params)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def record_path(server_id, destination, zone_name, view_name, record_id \\ nil) do
    destination =
      case {destination, record_id} do
        {:index, _} -> {:dns_zone_records, zone_name}
        {:new, _} -> {:dns_zone_record_new, zone_name}
        {:bulk, _} -> {:dns_zone_records_bulk, zone_name}
        {:edit, record_id} -> {:dns_zone_record_edit, zone_name, record_id}
      end

    ServicePaths.server_path(server_id, destination) <>
      "?" <> URI.encode_query(%{"view_name" => view_name})
  end

  defp load_records(socket, server_id) do
    payload = %{"view_name" => socket.assigns.view_name, "zone_name" => socket.assigns.zone_name}
    result = ServerManagement.dns_records_list(server_id, payload)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — DNS Records",
      records: ManagementSupport.items(result),
      management_error: if(ManagementSupport.error_result?(result), do: result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(
          [result],
          socket.assigns.selected_server.last_seen_at
        ),
      commands_enabled?: socket.assigns.service_online?
    )
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New DNS Record",
      record_form: to_form(@form, as: "record")
    )
  end

  defp apply_action(socket, :edit, %{"rr_index" => record_id}) do
    case Enum.find(socket.assigns.records, &(&1["record_id"] == record_id)) do
      nil ->
        socket
        |> assign(:record_form, to_form(@form, as: "record"))
        |> put_flash(:error, "Record is not present in the selected Server snapshot")

      record ->
        assign(socket,
          page_title: "Edit DNS Record",
          record_form: to_form(record_form_values(record), as: "record")
        )
    end
  end

  defp apply_action(socket, :bulk, _params), do: assign(socket, page_title: "Bulk DNS Records")
  defp apply_action(socket, :index, _params), do: socket

  defp record_form_values(record) do
    %{
      "record_id" => record["record_id"],
      "name" => record["name"],
      "type" => record["type"],
      "ttl" => to_string(record["ttl"]),
      "values" => Enum.join(record["values"] || [], "\n")
    }
  end

  defp record_payload(socket, params) do
    %{
      "view_name" => socket.assigns.view_name,
      "zone_name" => socket.assigns.zone_name,
      "record_id" => String.trim(params["record_id"] || ""),
      "name" => String.trim(params["name"] || ""),
      "type" => params["type"] || "A",
      "ttl" => ManagementSupport.integer(params["ttl"], 300),
      "values" => ManagementSupport.csv(params["values"])
    }
  end

  defp record_reference(socket, record_id) do
    %{
      "view_name" => socket.assigns.view_name,
      "zone_name" => socket.assigns.zone_name,
      "record_id" => record_id
    }
  end

  defp record_revision(records, record_id) do
    case ManagementSupport.find_digest(records, &(&1["record_id"] == record_id)) do
      revision when is_binary(revision) -> {:ok, revision}
      _missing -> {:error, "Record is not present in the selected Server snapshot"}
    end
  end

  defp put_resource(socket, result), do: put_resource(socket, result, nil)

  defp put_resource(
         socket,
         %ManagementResult{status: :ok, value: %{"resource" => resource}},
         previous_record_id
       ) do
    replaced_ids = MapSet.new([resource["record_id"], previous_record_id])

    records =
      [
        resource
        | Enum.reject(socket.assigns.records, &MapSet.member?(replaced_ids, &1["record_id"]))
      ]

    assign(socket, :records, Enum.sort_by(records, & &1["record_id"]))
  end

  defp put_resource(socket, _result, _previous_record_id), do: socket

  defp edit_route_identity(socket) do
    case {socket.assigns.live_action, socket.assigns.route_params["rr_index"]} do
      {:edit, record_id} when is_binary(record_id) and record_id != "" -> {:ok, record_id}
      _other -> {:error, "Record update requires an edit route"}
    end
  end

  defp record_form(assigns) do
    ~H"""
    <.form for={@form} id={@id} phx-submit={@event} class="space-y-3">
      <.input
        id={"#{@id}-record-id"}
        field={@form[:record_id]}
        label="Record ID"
        required
        readonly={@event == "update_record"}
      />
      <.input id={"#{@id}-name"} field={@form[:name]} label="Owner" required />
      <.input
        id={"#{@id}-type"}
        field={@form[:type]}
        type="select"
        label="Type"
        options={Enum.map(~w(A AAAA CNAME MX NS PTR SRV TXT), &{&1, &1})}
      />
      <.input id={"#{@id}-ttl"} field={@form[:ttl]} label="TTL" type="number" required />
      <.input
        id={"#{@id}-values"}
        field={@form[:values]}
        label="Values (comma or newline separated)"
        type="textarea"
        required
      />
      <button class="btn btn-primary" disabled={not @enabled?}>{@button}</button>
    </.form>
    """
  end
end
