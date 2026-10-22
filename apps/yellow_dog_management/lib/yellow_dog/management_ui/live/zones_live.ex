defmodule YellowDog.ManagementUI.ZonesLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.ConfigSpec
  alias YellowDog.Management.{Database, Domain, ZoneAssignmentChoices}
  alias YellowDog.ManagementUI.Hooks.CurrentPath
  alias YellowDog.ManagementUI.Submission

  @soa_fields ~w(mname rname serial refresh retry expire minimum)
  @numeric_fields ~w(serial refresh retry expire minimum)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(Submission.new(socket),
       navigation_workers: ZoneAssignmentChoices.navigation(),
       workers: [],
       assignment_candidates: nil,
       assignment_candidate_options: %{},
       zones: [],
       catalog: %{},
       catalog_options: %{},
       catalog_route: nil,
       content_dirty: false,
       content_reset: Ecto.UUID.generate(),
       assignment_reset: Ecto.UUID.generate(),
       assignment_submission_id: Ecto.UUID.generate(),
       assignment_submission_previous: nil,
       assignment_request: nil,
       affected_workers: [],
       filter: "",
       deleting: nil,
       zone: nil,
       versions: [],
       assignment_zone_id: nil,
       assignment_editable: false,
       assignment_canonical_rows: [],
       assignment_rows: [],
       assignment_token: nil,
       assignment_worker_revisions: %{},
       assignments_dirty: false,
       assignment_error: nil,
       rows: [],
       validation_errors: [],
       zone_valid?: false,
       form: to_form(%{"name" => ""}, as: "zone")
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    path_params = CurrentPath.route_path_params(socket, uri)
    route = URI.parse(uri).path
    same_route? = route == socket.assigns.catalog_route

    case base_path(path_params, socket.assigns.navigation_workers) do
      {:ok, base_path} ->
        {:noreply,
         apply_action(
           assign(socket,
             catalog_options: Map.take(params, ~w(search page page_size sort)),
             catalog_route: route
           ),
           path_params,
           base_path,
           same_route?
         )}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, error.message) |> push_navigate(to: "/server")}
    end
  end

  defp base_path(%{"server_id" => server_id}, workers) do
    if Enum.any?(workers, &(&1["id"] == server_id)),
      do: {:ok, "/server/#{URI.encode(server_id)}/dns/zones"},
      else: {:error, %{message: "Worker not found"}}
  end

  defp base_path(_params, _workers), do: {:ok, "/management/zones"}

  defp apply_action(socket, params, base_path, same_route?) do
    socket = socket |> assign(:base_path, base_path) |> load_catalog()

    socket =
      case socket.assigns.live_action do
        action when action in [:index, :new] and same_route? ->
          socket

        :index ->
          socket
          |> Submission.new()
          |> reset_assignments()
          |> assign(page_title: "DNS Zones", zone: nil, content_dirty: false)

        :new ->
          socket
          |> Submission.new()
          |> reset_assignments()
          |> assign(
            page_title: "New DNS Zone",
            deleting: nil,
            zone: nil,
            content_dirty: false,
            content_reset: Ecto.UUID.generate(),
            rows: [new_record("SOA"), new_record("NS")],
            form: to_form(%{"name" => ""}, as: "zone")
          )

        action when action in [:edit, :versions, :application] ->
          if socket.assigns.zone && socket.assigns.zone["id"] == params["zone_id"] do
            socket
          else
            case Domain.get_zone(params["zone_id"]) do
              {:ok, zone} ->
                load_zone(Submission.new(socket), zone)

              {:error, error} ->
                socket
                |> put_flash(:error, error.message)
                |> push_patch(to: query_path(base_path, socket.assigns.catalog_options))
            end
          end
      end

    if socket.assigns.live_action == :application and
         is_nil(socket.assigns.assignment_candidates),
       do: load_assignment_candidates(socket),
       else: socket
  end

  defp load_catalog(socket) do
    catalog = Domain.list_zone_catalog(socket.assigns.catalog_options)
    options = Map.take(catalog, Map.keys(socket.assigns.catalog_options))

    assign(socket,
      catalog: catalog,
      catalog_options: options,
      zones: catalog["zones"],
      filter: catalog["search"]
    )
  end

  @impl true
  def handle_event("save_assignments", params, socket) do
    token = params["_submission"]

    current? =
      is_binary(token) and
        (token == socket.assigns.assignment_submission_id or
           (match?({^token, _}, socket.assigns.assignment_submission_previous) and
              submitted_editor(socket, "save_assignments", params) == "set_zone_assignments"))

    if current?,
      do: handle_submission("save_assignments", params, socket),
      else: {:noreply, socket}
  end

  def handle_event(event, params, socket)
      when event in ~w(save confirm_delete confirm_zone) do
    if Submission.current?(
         socket,
         params["_submission"],
         submitted_editor(socket, event, params)
       ),
       do: handle_submission(event, params, socket),
       else: {:noreply, socket}
  end

  def handle_event("filter", %{"filter" => %{"name" => name}}, socket) when is_binary(name) do
    options =
      Map.merge(socket.assigns.catalog_options, %{
        "search" => String.slice(name, 0, 253),
        "page" => "1"
      })

    {:noreply,
     push_patch(socket, to: query_path(socket.assigns.catalog_route, options), replace: true)}
  end

  def handle_event("refresh", _params, socket) do
    socket = load_catalog(socket)

    socket =
      if socket.assigns.zone do
        id = socket.assigns.zone["id"]

        if match?({:ok, _}, Domain.get_zone(id)) do
          assign(socket, :versions, Domain.list_versions(id))
        else
          socket
          |> assign(zone: nil, rows: [], versions: [], form: to_form(%{"name" => ""}, as: "zone"))
          |> put_flash(
            :error,
            "Zone draft is no longer available. Historical versions are retained."
          )
          |> push_patch(to: query_path(socket.assigns.base_path, socket.assigns.catalog_options))
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("export_csv", _params, socket) do
    zones = Domain.list_zones()

    rows =
      zones
      |> visible_zones(socket.assigns.filter)
      |> Enum.map_join("", fn zone ->
        [zone["name"], "Authoritative", to_string(length(zone["records"])), "Unavailable"]
        |> Enum.map_join(",", &csv_cell/1)
        |> Kernel.<>("\r\n")
      end)

    {:noreply,
     socket
     |> load_catalog()
     |> push_event("download_csv", %{
       content: "Name,Type,Record count,Query count\r\n" <> rows,
       filename: "management_zones.csv"
     })}
  end

  def handle_event("validate", %{"zone" => params}, socket) do
    rows = record_rows(params)

    socket =
      if params != socket.assigns.form.params or rows != socket.assigns.rows,
        do: Submission.edit(socket, ~w(create_zone update_zone)),
        else: socket

    {:noreply, socket |> assign_form(params, rows) |> assign(:content_dirty, true)}
  end

  def handle_event(
        "filter_assignment_candidates",
        %{"candidates" => %{"search" => search}},
        socket
      )
      when is_binary(search) do
    {:noreply,
     socket
     |> assign(:assignment_candidate_options, %{"search" => search, "page" => "1"})
     |> load_assignment_candidates()}
  end

  def handle_event("assignment_candidates_page", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(
       :assignment_candidate_options,
       Map.put(socket.assigns.assignment_candidate_options, "page", page)
     )
     |> load_assignment_candidates()}
  end

  def handle_event("add_assignment_worker", %{"id" => worker_id}, socket) do
    candidates = socket.assigns.assignment_candidates
    worker = candidates && Enum.find(candidates["workers"], &(&1["id"] == worker_id))
    services = if worker, do: dns_services(worker), else: []

    cond do
      is_nil(socket.assigns.zone) || socket.assigns.versions == [] ->
        {:noreply,
         assign(socket, assignment_error: "Confirm a Zone version before assigning it.")}

      services == [] ->
        {:noreply,
         assign(socket,
           assignment_error: "Configure a DNS Service for the selected Worker first."
         )}

      length(socket.assigns.assignment_rows) >= 256 ->
        {:noreply,
         assign(socket,
           assignment_error:
             "At most 256 assignments can be edited. Remove a selection before adding another."
         )}

      true ->
        service_id =
          if worker["dns_service_count"] == 1, do: hd(services)["id"], else: ""

        row = %{
          "key" => Ecto.UUID.generate(),
          "worker_id" => worker_id,
          "service_id" => service_id,
          "resource_version_id" => List.last(socket.assigns.versions)["id"]
        }

        {:noreply,
         assign(edit_assignment_intent(socket),
           assignment_rows: socket.assigns.assignment_rows ++ [row],
           assignments_dirty: true,
           assignment_error: nil
         )}
    end
  end

  def handle_event("remove_assignment_row", %{"key" => key}, socket) do
    rows = Enum.reject(socket.assigns.assignment_rows, &(&1["key"] == key))

    {:noreply,
     assign(edit_assignment_intent(socket),
       assignment_rows: rows,
       assignments_dirty: true,
       assignment_error: nil
     )}
  end

  def handle_event("validate_assignments", %{"assignments" => params}, socket)
      when is_map(params) do
    updated = retain_assignments(socket, params)

    socket =
      if updated.assigns.assignment_rows != socket.assigns.assignment_rows,
        do: edit_assignment_intent(updated),
        else: updated

    {:noreply, socket}
  end

  def handle_event("refresh_assignments", _params, socket) do
    if socket.assigns.zone do
      {:noreply,
       load_assignments(
         reset_assignment_intent(socket),
         socket.assigns.zone["id"]
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("discard_content", _params, socket) do
    case Domain.get_zone(socket.assigns.zone["id"]) do
      {:ok, zone} ->
        {:noreply,
         load_zone(Submission.edit(socket, ~w(create_zone update_zone confirm_zone)), zone)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("add_record", _params, socket) do
    rows = socket.assigns.rows ++ [new_record("A")]

    {:noreply,
     assign_form(
       socket |> Submission.edit(~w(create_zone update_zone)) |> assign(:content_dirty, true),
       socket.assigns.form.params,
       rows
     )}
  end

  def handle_event("remove_record", %{"index" => index}, socket) do
    rows =
      socket.assigns.rows
      |> Enum.with_index()
      |> Enum.reject(fn {_row, ordinal} -> to_string(ordinal) == index end)
      |> Enum.map(&elem(&1, 0))

    {:noreply,
     assign_form(
       socket |> Submission.edit(~w(create_zone update_zone)) |> assign(:content_dirty, true),
       socket.assigns.form.params,
       rows
     )}
  end

  def handle_event("delete_zone", %{"id" => id}, socket) do
    case cached_zone(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Zone is no longer available. Refresh the list.")}

      zone ->
        {:noreply, assign(socket, :deleting, zone)}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :deleting, nil)}
  end

  defp cached_zone(socket, id) do
    if socket.assigns.zone && socket.assigns.zone["id"] == id,
      do: socket.assigns.zone,
      else: Enum.find(socket.assigns.zones, &(&1["id"] == id))
  end

  defp visible_zones(zones, filter) do
    query = String.downcase(filter)
    Enum.filter(zones, &String.contains?(String.downcase(&1["name"]), query))
  end

  defp catalog_path(base, catalog, page) do
    base <>
      "?" <>
      URI.encode_query(%{
        "search" => catalog["search"],
        "sort" => catalog["sort"],
        "page" => page,
        "page_size" => catalog["page_size"]
      })
  end

  defp query_path(path, options) when map_size(options) == 0, do: path
  defp query_path(path, options), do: path <> "?" <> URI.encode_query(options)

  defp csv_cell(value) do
    value = if Regex.match?(~r/\A(?:[\t\r\n]|\s*[=+\-@])/u, value), do: "'" <> value, else: value

    if String.contains?(value, [",", "\"", "\r", "\n"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end

  defp submitted_editor(socket, "save", %{"zone" => params}) when is_map(params) do
    records = params["records"]

    if is_map(records) and
         Enum.all?(records, fn {index, record} ->
           is_binary(index) and is_map(record) and
             (is_nil(record["data"]) or is_map(record["data"]))
         end) and
         params["name"] == socket.assigns.form.params["name"] and
         record_rows(params) == socket.assigns.rows,
       do: if(socket.assigns.zone, do: "update_zone", else: "create_zone")
  end

  defp submitted_editor(socket, "save_assignments", %{"assignments" => params})
       when is_map(params) do
    current =
      Map.new(
        socket.assigns.assignment_rows,
        &{&1["key"], Map.take(&1, ~w(service_id resource_version_id))}
      )

    if params == current, do: "set_zone_assignments"
  end

  defp submitted_editor(_socket, _event, _params), do: nil

  defp handle_submission("save_assignments", params, socket) do
    socket = retain_assignments(socket, params["assignments"] || %{})

    if socket.assigns.zone do
      payload = %{
        "zone_id" => socket.assigns.zone["id"],
        "expected_assignment_token" => socket.assigns.assignment_token,
        "expected_worker_revisions" => socket.assigns.assignment_worker_revisions,
        "assignments" =>
          Enum.map(
            socket.assigns.assignment_rows,
            &Map.take(&1, ~w(worker_id service_id resource_version_id))
          )
      }

      {socket, key} = prepare_assignment_intent(socket, payload, params["_submission"])

      case YellowDog.ManagementUI.Commands.command(socket, "set_zone_assignments", payload, key) do
        {:ok, snapshot} ->
          {:noreply,
           socket
           |> reset_assignment_intent()
           |> assign(
             :affected_workers,
             Enum.uniq(
               Enum.map(socket.assigns.assignment_rows, & &1["worker_id"]) ++
                 Enum.map(socket.assigns.assignment_canonical_rows, & &1["worker_id"])
             )
           )
           |> apply_assignment_snapshot(snapshot)
           |> put_flash(:info, "Worker assignments saved. No target was prepared or delivered.")}

        {:error, error} ->
          {:noreply, assign(socket, assignment_error: error[:message] || error["message"])}
      end
    else
      {:noreply,
       assign(socket, assignment_error: "Save and confirm a Zone version before assigning it.")}
    end
  end

  defp handle_submission("save", %{"zone" => params} = event, socket) do
    rows = record_rows(params)
    payload = %{"name" => params["name"], "records" => Enum.map(rows, &normalize_record/1)}
    zone = socket.assigns.zone
    operation = if zone, do: "update_zone", else: "create_zone"

    payload =
      if zone,
        do: Map.merge(payload, %{"id" => zone["id"], "expected_revision" => zone["revision"]}),
        else: payload

    {socket, key} = Submission.prepare(socket, operation, payload, event["_submission"])

    case YellowDog.ManagementUI.Commands.command(socket, operation, payload, key) do
      {:ok, saved} ->
        read =
          Database.read(fn ->
            with {:ok, zone} <- Domain.get_zone(saved["id"]), do: {:ok, load_zone(socket, zone)}
          end)

        case read do
          {:ok, {:ok, loaded}} ->
            {:noreply,
             loaded
             |> Submission.edit(~w(create_zone update_zone))
             |> put_flash(
               :info,
               "Zone draft saved. Confirm a version before assigning it to a service."
             )
             |> push_patch(
               to:
                 query_path(
                   "#{socket.assigns.base_path}/#{saved["id"]}/edit",
                   socket.assigns.catalog_options
                 )
             )}

          _ ->
            {:noreply,
             socket
             |> assign_form(params, rows)
             |> assign(:content_dirty, true)
             |> put_flash(
               :error,
               "Zone was saved, but its canonical draft could not be read. Your input and request are retained; retry to check the saved result."
             )}
        end

      {:error, error} ->
        {:noreply,
         socket
         |> assign_form(params, rows)
         |> assign(:content_dirty, true)
         |> put_flash(:error, error.message)}
    end
  end

  defp handle_submission("confirm_delete", %{"id" => id} = event, socket) do
    case socket.assigns.deleting do
      %{"id" => ^id} = zone ->
        payload = %{"id" => id, "expected_revision" => zone["revision"]}
        {socket, key} = Submission.prepare(socket, "delete_zone", payload, event["_submission"])

        case YellowDog.ManagementUI.Commands.command(socket, "delete_zone", payload, key) do
          {:ok, _result} ->
            socket =
              socket
              |> Submission.new()
              |> load_catalog()
              |> assign(deleting: nil)
              |> put_flash(:info, "Zone draft deleted. Historical versions are retained.")

            socket =
              if socket.assigns.zone && socket.assigns.zone["id"] == id,
                do:
                  push_patch(socket,
                    to: query_path(socket.assigns.base_path, socket.assigns.catalog_options)
                  ),
                else: socket

            {:noreply, socket}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, error.message)}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Select a Zone and confirm its deletion first.")}
    end
  end

  defp handle_submission("confirm_delete", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select a Zone and confirm its deletion first.")}
  end

  defp handle_submission("confirm_zone", %{"id" => id} = event, socket) do
    zone = cached_zone(socket, id)

    if zone && !socket.assigns.content_dirty do
      payload = %{"id" => id, "expected_revision" => zone["revision"]}
      {socket, key} = Submission.prepare(socket, "confirm_zone", payload, event["_submission"])

      case YellowDog.ManagementUI.Commands.command(socket, "confirm_zone", payload, key) do
        {:ok, _result} ->
          socket =
            socket
            |> Submission.edit(["confirm_zone"])
            |> load_catalog()
            |> put_flash(
              :info,
              "Immutable Zone version confirmed. No Worker runtime was changed."
            )

          socket =
            if socket.assigns.zone && socket.assigns.zone["id"] == id,
              do: assign(socket, :versions, Domain.list_versions(id)),
              else: socket

          {:noreply, socket}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error.message)}
      end
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Save or explicitly discard unsaved content before confirming the saved draft."
       )}
    end
  end

  defp handle_submission(_event, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid submission")}

  defp load_zone(socket, zone) do
    socket =
      if socket.assigns.assignment_zone_id != zone["id"],
        do: reset_assignments(socket),
        else: socket

    preserve_assignments =
      socket.assigns.assignment_zone_id == zone["id"] &&
        (socket.assigns.assignments_dirty || not is_nil(socket.assigns.assignment_request))

    socket =
      socket
      |> assign(
        page_title: "Edit DNS Zone",
        zone: zone,
        versions: Domain.list_versions(zone["id"]),
        content_dirty: false,
        content_reset: Ecto.UUID.generate()
      )
      |> assign_form(%{"name" => zone["name"]}, zone["records"])

    if preserve_assignments, do: socket, else: load_assignments(socket, zone["id"])
  end

  defp load_assignments(socket, zone_id) do
    case Domain.get_zone_assignments(zone_id) do
      {:ok, snapshot} ->
        socket |> apply_assignment_snapshot(snapshot) |> load_selected_assignment_workers()

      {:error, error} ->
        assign(socket,
          assignment_editable: false,
          assignment_error: error[:message] || error["message"]
        )
    end
  end

  defp apply_assignment_snapshot(socket, snapshot) do
    rows = Enum.map(snapshot["assignments"], &Map.put(&1, "key", &1["id"]))

    assign(socket,
      assignment_zone_id: snapshot["zone_id"],
      assignment_editable: true,
      assignment_rows: rows,
      assignment_canonical_rows: rows,
      assignment_reset: Ecto.UUID.generate(),
      assignment_token: snapshot["assignment_token"],
      assignment_worker_revisions: snapshot["worker_revisions"],
      assignments_dirty: false,
      assignment_error: nil
    )
  end

  defp retain_assignments(socket, params) do
    rows =
      Enum.map(socket.assigns.assignment_rows, fn row ->
        Map.merge(row, Map.take(params[row["key"]] || %{}, ~w(service_id resource_version_id)))
      end)

    assign(socket,
      assignment_rows: rows,
      assignments_dirty:
        socket.assigns.assignments_dirty || rows != socket.assigns.assignment_rows,
      assignment_error: nil
    )
  end

  defp reset_assignments(socket),
    do:
      assign(reset_assignment_intent(socket),
        assignment_zone_id: nil,
        workers: [],
        assignment_candidates: nil,
        assignment_candidate_options: %{},
        assignment_editable: false,
        affected_workers: [],
        assignment_rows: [],
        assignment_canonical_rows: [],
        assignment_reset: Ecto.UUID.generate(),
        assignment_token: nil,
        assignment_worker_revisions: %{},
        assignments_dirty: false,
        assignment_error: nil
      )

  defp edit_assignment_intent(socket) do
    if socket.assigns.assignment_request do
      assign(socket,
        assignment_submission_id: Ecto.UUID.generate(),
        assignment_submission_previous:
          {socket.assigns.assignment_submission_id, socket.assigns.assignment_request},
        assignment_request: nil
      )
    else
      socket
    end
  end

  defp reset_assignment_intent(socket) do
    assign(socket,
      assignment_submission_id: Ecto.UUID.generate(),
      assignment_submission_previous: nil,
      assignment_request: nil
    )
  end

  defp prepare_assignment_intent(socket, payload, token) do
    socket = clear_flash(socket, :info)

    case socket.assigns.assignment_submission_previous do
      {^token, {^payload, key}} ->
        {socket, key}

      _ ->
        case socket.assigns.assignment_request do
          {^payload, key} ->
            {socket, key}

          previous ->
            key = Ecto.UUID.generate()
            socket = if previous, do: edit_assignment_intent(socket), else: socket
            {assign(socket, :assignment_request, {payload, key}), key}
        end
    end
  end

  defp dns_services(worker), do: Enum.filter(worker["services"], &(&1["type"] == "dns"))

  defp load_assignment_candidates(socket) do
    if socket.assigns.live_action == :application do
      socket
      |> assign(
        :assignment_candidates,
        ZoneAssignmentChoices.candidates(socket.assigns.assignment_candidate_options)
      )
      |> load_selected_assignment_workers()
    else
      socket
    end
  end

  defp load_selected_assignment_workers(socket) do
    selected = ZoneAssignmentChoices.selected(socket.assigns.assignment_rows)

    candidates =
      if socket.assigns.assignment_candidates,
        do: socket.assigns.assignment_candidates["workers"],
        else: []

    workers =
      (selected ++ candidates)
      |> Enum.group_by(& &1["id"])
      |> Enum.map(fn {_id, workers} ->
        services =
          workers
          |> Enum.flat_map(& &1["services"])
          |> Enum.uniq_by(& &1["id"])
          |> Enum.sort_by(&{&1["instance_id"], &1["id"]})

        Map.put(hd(workers), "services", services)
      end)

    assign(socket, :workers, workers)
  end

  defp assignment_worker(workers, row), do: Enum.find(workers, &(&1["id"] == row["worker_id"]))

  defp assign_form(socket, params, rows) do
    errors =
      case ConfigSpec.normalize_resource(%{
             "id" => "zone-draft",
             "type" => "dns_zone",
             "schema_version" => 1,
             "version" => 1,
             "content" => %{
               "name" => params["name"],
               "records" => Enum.map(rows, &normalize_record/1)
             }
           }) do
        {:ok, _resource} -> []
        {:error, errors} -> errors
      end

    assign(socket,
      form: to_form(params, as: "zone"),
      rows: rows,
      validation_errors: errors,
      zone_valid?: errors == []
    )
  end

  defp record_rows(params) do
    params
    |> Map.get("records", %{})
    |> Enum.sort_by(fn {index, _record} -> {String.length(index), index} end)
    |> Enum.map(fn {_index, record} ->
      Map.put(record, "data", Map.take(record["data"] || %{}, data_fields(record["type"])))
    end)
  end

  defp normalize_record(record) do
    data =
      Map.new(record["data"], fn {field, value} ->
        {field, if(field in @numeric_fields, do: integer(value), else: value)}
      end)

    record
    |> Map.take(~w(name type ttl))
    |> Map.put("ttl", integer(record["ttl"]))
    |> Map.put("data", data)
  end

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp integer(value), do: value

  defp new_record(type) do
    data =
      case type do
        "SOA" ->
          %{
            "mname" => "",
            "rname" => "",
            "serial" => 1,
            "refresh" => 3600,
            "retry" => 600,
            "expire" => 86400,
            "minimum" => 300
          }

        "NS" ->
          %{"host" => ""}

        "A" ->
          %{"address" => ""}
      end

    %{"name" => "", "type" => type, "ttl" => 300, "data" => data}
  end

  defp data_fields("SOA"), do: @soa_fields
  defp data_fields("NS"), do: ["host"]
  defp data_fields("A"), do: ["address"]
  defp data_fields(_type), do: []

  defp numeric_field?(field), do: field in @numeric_fields

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible_zones, assigns.zones)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      servers={Enum.map(@navigation_workers, &%{id: &1["id"], name: &1["name"]})}
    >
      <div id="zone-workflow" phx-hook="EditorGuard">
        <input id="submission-intent" type="hidden" value={@submission_id} />
        <h1>{@page_title}</h1>
        <p class="management-help">
          Global reusable Zone library: Management-owned DNS drafts and immutable versions, not View-owned content. Actual Worker runtime state is unknown. SOA, NS and A records are supported by the current shared contract.
        </p>
        <p class="management-help">
          Only authoritative Zones are supported. Forward, stub, cloud and additional record types remain pending. Runtime query counts are unavailable.
        </p>
        <div class="management-actions">
          <.link patch={query_path(@base_path, @catalog_options)} class="btn btn-ghost">Zones</.link>
          <.link patch={query_path(@base_path <> "/new", @catalog_options)} class="btn btn-primary">New Zone</.link>
          <.link navigate={@base_path <> "/import"} class="btn btn-ghost">Import Zone</.link>
          <button id="zone-refresh" class="btn btn-ghost" phx-click="refresh">Refresh</button>
          <button id="zone-export" class="btn btn-ghost" phx-hook="CsvDownload" phx-click="export_csv">Export all matching Zones CSV</button>
        </div>
        <form id="zones-filter-form" phx-change="filter" phx-submit="filter">
          <label class="management-field"><span>Filter Zone names</span><input
            id="zone-filter"
            class="input"
            name="filter[name]"
            value={@filter}
            maxlength="253"
          /></label>
        </form>
        <p id="zone-count" data-displayed={length(@zones)} data-total={@catalog["total"]}>
          {length(@zones)} of {@catalog["total"]} Zones shown. Page {@catalog["page"]} (up to {@catalog[
            "page_size"
          ]} per page).
        </p>
        <nav aria-label="Zone catalog pages" class="management-actions">
          <.link
            :if={@catalog["page"] > 1}
            patch={catalog_path(@base_path, @catalog, @catalog["page"] - 1)}
          >Previous page</.link>
          <.link
            :if={@catalog["has_next"]}
            patch={catalog_path(@base_path, @catalog, @catalog["page"] + 1)}
          >Next page</.link>
          <.link patch={catalog_path(@base_path, Map.put(@catalog, "sort", "name"), 1)}>Sort by name</.link>
          <.link patch={catalog_path(@base_path, Map.put(@catalog, "sort", "revision"), 1)}>Sort by revision</.link>
        </nav>
        <nav :if={@zone} aria-label="Zone detail" class="management-actions">
          <.link
            data-editor-preserve="true"
            patch={query_path("#{@base_path}/#{@zone["id"]}/edit", @catalog_options)}
          >Content</.link>
          <.link
            data-editor-preserve="true"
            patch={query_path("#{@base_path}/#{@zone["id"]}/versions", @catalog_options)}
          >Versions</.link>
          <.link
            data-editor-preserve="true"
            patch={query_path("#{@base_path}/#{@zone["id"]}/application", @catalog_options)}
          >Application scope</.link>
        </nav>
        <.card :if={@live_action == :index} title="DNS Zones">
          <p :if={@catalog["total"] == 0}>
            No zones configured. Create a Zone without registering a Worker.
          </p>
          <p :if={@catalog["total"] > 0 and @visible_zones == []}>No Zone names match this filter.</p>
          <div class="management-records">
            <table id="zones-table" class="table table-striped">
              <thead>
                <tr>
                  <th>Zone / identity</th><th>Draft revision</th><th>Records</th><th>
                    Latest confirmed
                  </th><th>Usage</th><th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={zone <- @visible_zones} id={"zone-#{zone["id"]}"}>
                  <td>{zone["name"]}<br /><code>{zone["id"]}</code></td><td>{zone["revision"]}</td><td>
                    {zone["record_count"]}
                  </td>
                  <td>{zone["latest_version"] || "No confirmed version"}</td>
                  <td>{zone["worker_count"]} Workers / {zone["service_count"]} services</td>
                  <td>
                    <div class="management-actions">
                      <.link
                        patch={query_path("#{@base_path}/#{zone["id"]}/edit", @catalog_options)}
                        class="btn btn-ghost"
                      >Edit</.link>
                      <.link navigate={"#{@base_path}/#{zone["id"]}/records"} class="btn btn-ghost">Records</.link>
                      <button
                        class="btn btn-primary"
                        phx-click="confirm_zone"
                        phx-value-_submission={@submission_id}
                        phx-disable-with="Confirming…"
                        phx-value-id={zone["id"]}
                      >Confirm Version</button>
                      <button
                        class="btn btn-error"
                        phx-click="delete_zone"
                        phx-value-id={zone["id"]}
                      >Delete</button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
        <div :if={@live_action != :index} hidden={@live_action not in [:new, :edit]}>
          <.card title="Zone Draft">
            <.form
              for={@form}
              id="zone-form"
              phx-change="validate"
              phx-submit="save"
              data-editor="true"
              data-editor-dirty={to_string(@content_dirty)}
              data-editor-reset={@content_reset}
            >
              <input type="hidden" name="_submission" value={@submission_id} />
              <label class="management-field"><span>Zone name (fully qualified)</span><input
                id="zone-name"
                class="input"
                name="zone[name]"
                value={@form[:name].value}
                required
              /></label>
              <p :if={@zone}>Draft revision {@zone["revision"]}</p>
              <div
                :if={@validation_errors != []}
                id="zone-validation-errors"
                class="alert alert-error"
                role="alert"
              >
                <ul>
                  <li :for={error <- @validation_errors}>
                    {Enum.map_join(error.path, ".", &to_string/1)}: {error.message}
                  </li>
                </ul>
              </div>
              <fieldset :for={{record, index} <- Enum.with_index(@rows)} id={"zone-record-#{index}"}>
                <legend>Record {index + 1}</legend>
                <label class="management-field"><span>Record name</span><input
                  class="input"
                  name={"zone[records][#{index}][name]"}
                  value={record["name"]}
                  required
                /></label>
                <label class="management-field"><span>Type</span><select
                  class="select"
                  name={"zone[records][#{index}][type]"}
                ><option :for={type <- ~w(SOA NS A)} value={type} selected={type == record["type"]}>
                  {type}
                </option></select></label>
                <label class="management-field"><span>TTL (seconds)</span><input
                  class="input"
                  type="number"
                  min="0"
                  name={"zone[records][#{index}][ttl]"}
                  value={record["ttl"]}
                  required
                /></label>
                <label :for={field <- data_fields(record["type"])} class="management-field">
                  <span>{field}</span><input
                    class="input"
                    type={if numeric_field?(field), do: "number", else: "text"}
                    min={if numeric_field?(field), do: "0"}
                    name={"zone[records][#{index}][data][#{field}]"}
                    value={record["data"][field]}
                    required
                  />
                </label>
                <button
                  type="button"
                  class="btn btn-ghost"
                  phx-click="remove_record"
                  phx-value-index={index}
                >Remove Record</button>
              </fieldset>
              <div class="management-actions">
                <button type="button" class="btn btn-ghost" phx-click="add_record">Add Record</button>
                <button
                  id="zone-save"
                  type="submit"
                  class="btn btn-primary"
                  disabled={!@zone_valid?}
                  phx-disable-with="Saving…"
                >Save Draft</button>
                <.link patch={query_path(@base_path, @catalog_options)} class="btn btn-ghost">Cancel</.link>
              </div>
            </.form>
            <div :if={@zone} class="management-actions">
              <.link navigate={"#{@base_path}/#{@zone["id"]}/records"} class="btn btn-ghost">Records</.link>
              <.link
                data-editor-preserve="true"
                patch={query_path("#{@base_path}/#{@zone["id"]}/versions", @catalog_options)}
                class="btn btn-primary"
              >Review saved versions</.link>
              <button
                :if={@zone}
                type="button"
                class="btn btn-ghost"
                phx-click="discard_content"
                data-editor-discard="zone-form"
              >Discard content edits</button>
              <button
                class="btn btn-error"
                phx-click="delete_zone"
                phx-value-id={@zone["id"]}
              >Delete</button>
            </div>
          </.card>
        </div>
        <div :if={@zone} hidden={@live_action != :application}>
          <.card title="Application scope">
            <p>
              All DNS services on one Worker must pin the same version of this Zone. Saving does not publish a target.
            </p>
            <p :for={worker_id <- @affected_workers}>
              <.link navigate={ServicePaths.server_path(worker_id, :targets)}>Review target for {worker_id}</.link>
            </p>
            <p class="management-help">
              Zone data is global. Assign a confirmed version to each logical Worker and DNS Service; assignments do not report execution.
            </p>
            <p :if={@versions == []}>
              Confirm a version before assigning this Zone. The draft remains editable.
            </p>
            <p
              :if={@assignment_error}
              id="zone-assignment-error"
              class="alert alert-error"
              role="alert"
            >
              {@assignment_error}
            </p>
            <form
              :if={@assignment_candidates}
              id="zone-assignment-candidates-filter"
              phx-change="filter_assignment_candidates"
              phx-submit="filter_assignment_candidates"
            >
              <label class="management-field">
                <span>Find Workers or DNS Services</span>
                <input
                  class="input"
                  name="candidates[search]"
                  value={@assignment_candidates["search"]}
                  maxlength="253"
                />
              </label>
            </form>
            <p
              :if={@assignment_candidates}
              id="zone-assignment-candidate-count"
              data-displayed={@assignment_candidates["displayed"]}
            >
              {@assignment_candidates["displayed"]} of {@assignment_candidates["total"]} Worker / DNS Service choices. Page {@assignment_candidates[
                "page"
              ]}.
              Selected assignments remain visible below. Service choices follow this search and page; selected services are always retained.
            </p>
            <div :if={@assignment_candidates} class="management-actions">
              <button
                :if={@assignment_candidates["page"] > 1}
                type="button"
                class="btn btn-ghost"
                phx-click="assignment_candidates_page"
                phx-value-page={@assignment_candidates["page"] - 1}
              >Previous choices</button>
              <button
                :if={@assignment_candidates["has_next"]}
                type="button"
                class="btn btn-ghost"
                phx-click="assignment_candidates_page"
                phx-value-page={@assignment_candidates["page"] + 1}
              >Next choices</button>
            </div>
            <div
              :if={@assignment_candidates}
              id="zone-assignment-candidates"
              class="management-actions"
            >
              <button
                :for={worker <- @assignment_candidates["workers"]}
                class="btn btn-secondary"
                phx-click="add_assignment_worker"
                phx-value-id={worker["id"]}
                disabled={!@assignment_editable || @versions == [] || dns_services(worker) == []}
              >
                Assign {worker["name"]} ({worker["id"]})
              </button>
            </div>
            <p :if={@navigation_workers == []}>
              No logical Workers are registered. Zone drafts and versions remain global.
            </p>
            <p
              :for={worker <- (@assignment_candidates && @assignment_candidates["workers"]) || []}
              :if={dns_services(worker) == []}
            >
              {worker["name"]} has no DNS Services.
              <.link navigate={ServicePaths.server_path(worker["id"], :service_new)}>Configure a DNS Service</.link>
            </p>
            <form
              id="zone-assignments-form"
              data-editor="true"
              data-editor-dirty={to_string(@assignments_dirty)}
              data-editor-reset={@assignment_reset}
              phx-change="validate_assignments"
              phx-submit="save_assignments"
            >
              <input type="hidden" name="_submission" value={@assignment_submission_id} />
              <fieldset
                :for={row <- @assignment_rows}
                id={"zone-assignment-#{row["key"]}"}
                data-worker-id={row["worker_id"]}
              >
                <legend>{assignment_worker(@workers, row)["name"]} ({row["worker_id"]})</legend>
                <label class="management-field">
                  <span>DNS Service</span>
                  <select class="select" name={"assignments[#{row["key"]}][service_id]"} required>
                    <option value="" selected={row["service_id"] == ""}>Select a DNS Service</option>
                    <option
                      :for={service <- dns_services(assignment_worker(@workers, row))}
                      value={service["id"]}
                      selected={row["service_id"] == service["id"]}
                    >
                      {service["instance_id"]} ({service["id"]})
                    </option>
                  </select>
                </label>
                <label class="management-field">
                  <span>Confirmed Zone version</span>
                  <select
                    class="select"
                    name={"assignments[#{row["key"]}][resource_version_id]"}
                    required
                  >
                    <option
                      :for={version <- @versions}
                      value={version["id"]}
                      selected={row["resource_version_id"] == version["id"]}
                    >
                      Version {version["version"]} — {version["digest"]}
                    </option>
                  </select>
                </label>
                <button
                  type="button"
                  class="btn btn-error"
                  phx-click="remove_assignment_row"
                  phx-value-key={row["key"]}
                >Remove assignment</button>
              </fieldset>
              <div class="management-actions">
                <button
                  id="zone-save-assignments"
                  class="btn btn-primary"
                  type="submit"
                  phx-disable-with="Saving assignments…"
                  disabled={!@assignment_editable || (@versions == [] && @assignment_rows == [])}
                >Save assignments</button>
                <button
                  type="button"
                  class="btn btn-secondary"
                  phx-click="refresh_assignments"
                  data-editor-discard="zone-assignments-form"
                >Reload assignment set</button>
              </div>
            </form>
          </.card>
        </div>
        <.card :if={@deleting} title="Confirm Zone deletion">
          <div
            id="zone-delete-confirmation"
            data-zone-id={@deleting["id"]}
            data-revision={@deleting["revision"]}
          >
            <p>
              Delete {@deleting["name"]} at draft revision {@deleting["revision"]}? Historical versions will be retained. No Worker runtime is changed.
            </p>
            <div class="management-actions">
              <button
                id="zone-delete-confirm"
                class="btn btn-error"
                phx-click="confirm_delete"
                phx-value-_submission={@submission_id}
                phx-disable-with="Deleting…"
                phx-value-id={@deleting["id"]}
              >Confirm Delete</button>
              <button id="zone-cancel-delete" class="btn btn-ghost" phx-click="cancel_delete">Cancel Delete</button>
            </div>
          </div>
        </.card>
        <div :if={@zone} hidden={@live_action != :versions}>
          <.card title="Immutable Versions">
            <p>
              Confirm saved draft revision {@zone["revision"]}. Save or explicitly discard content edits first.
            </p>
            <button
              id="zone-confirm-version"
              data-editor-confirm="zone-form"
              phx-click="confirm_zone"
              phx-value-id={@zone["id"]}
              phx-value-_submission={@submission_id}
              disabled={@content_dirty}
              class="btn btn-primary"
            >Confirm Version</button>
            <p :if={@versions == []}>
              No confirmed versions. Saving a draft does not change an assigned version.
            </p>
            <div class="management-records">
              <table id="zone-versions" class="table">
                <thead>
                  <tr>
                    <th>Version</th><th>Source revision</th><th>Digest / frozen content</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={version <- @versions}>
                    <td>{version["version"]}</td><td>{version["source_revision"]}</td><td>
                      {version["digest"]}
                      <details>
                        <summary>Frozen {version["content"]["name"]}</summary><pre>{Jason.encode!(version["content"], pretty: true)}</pre>
                      </details>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
