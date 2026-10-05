defmodule YellowDog.ManagementUI.ZonesLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.ConfigSpec
  alias YellowDog.Management.Domain
  alias YellowDog.ManagementUI.Hooks.CurrentPath
  alias YellowDog.ManagementUI.Submission

  @soa_fields ~w(mname rname serial refresh retry expire minimum)
  @numeric_fields ~w(serial refresh retry expire minimum)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       workers: assignment_workers(),
       zones: [],
       filter: "",
       deleting: nil,
       zone: nil,
       versions: [],
       assignment_zone_id: nil,
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
  def handle_params(_params, uri, socket) do
    path_params = CurrentPath.route_path_params(socket, uri)

    case base_path(path_params) do
      {:ok, base_path} ->
        {:noreply, apply_action(socket, path_params, base_path)}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, error.message) |> push_navigate(to: "/server")}
    end
  end

  defp base_path(%{"server_id" => server_id}) do
    with {:ok, _worker} <- Domain.get_worker(server_id) do
      {:ok, "/server/#{URI.encode(server_id)}/dns/zones"}
    end
  end

  defp base_path(_params), do: {:ok, "/management/zones"}

  defp apply_action(socket, params, base_path) do
    socket =
      assign(socket,
        base_path: base_path,
        zones: Domain.list_zones(),
        zone: nil,
        versions: [],
        validation_errors: [],
        zone_valid?: false,
        deleting: nil
      )

    case socket.assigns.live_action do
      :index ->
        socket |> reset_assignments() |> assign(page_title: "DNS Zones")

      :new ->
        socket
        |> reset_assignments()
        |> assign(
          page_title: "New DNS Zone",
          rows: [new_record("SOA"), new_record("NS")],
          form: to_form(%{"name" => ""}, as: "zone")
        )

      :edit ->
        case Domain.get_zone(params["zone_id"]) do
          {:ok, zone} ->
            load_zone(socket, zone)

          {:error, error} ->
            socket |> put_flash(:error, error.message) |> push_patch(to: base_path)
        end
    end
  end

  @impl true
  def handle_event("filter", %{"filter" => %{"name" => name}}, socket) when is_binary(name) do
    {:noreply, assign(socket, :filter, String.slice(name, 0, 253))}
  end

  def handle_event("refresh", _params, socket) do
    socket = assign(socket, :zones, Domain.list_zones())

    socket =
      if socket.assigns.zone do
        id = socket.assigns.zone["id"]

        if Enum.any?(socket.assigns.zones, &(&1["id"] == id)) do
          assign(socket, :versions, Domain.list_versions(id))
        else
          socket
          |> assign(zone: nil, rows: [], versions: [], form: to_form(%{"name" => ""}, as: "zone"))
          |> put_flash(
            :error,
            "Zone draft is no longer available. Historical versions are retained."
          )
          |> push_patch(to: socket.assigns.base_path)
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
     |> assign(:zones, zones)
     |> push_event("download_csv", %{
       content: "Name,Type,Record count,Query count\r\n" <> rows,
       filename: "management_zones.csv"
     })}
  end

  def handle_event("validate", %{"zone" => params}, socket) do
    {:noreply, assign_form(socket, params, record_rows(params))}
  end

  def handle_event("add_assignment_worker", %{"id" => worker_id}, socket) do
    worker = Enum.find(socket.assigns.workers, &(&1["id"] == worker_id))
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

      true ->
        service_id =
          case services do
            [service] -> service["id"]
            _ -> ""
          end

        row = %{
          "key" => Ecto.UUID.generate(),
          "worker_id" => worker_id,
          "service_id" => service_id,
          "resource_version_id" => hd(socket.assigns.versions)["id"]
        }

        {:noreply,
         assign(socket,
           assignment_rows: socket.assigns.assignment_rows ++ [row],
           assignments_dirty: true,
           assignment_error: nil
         )}
    end
  end

  def handle_event("remove_assignment_row", %{"key" => key}, socket) do
    rows = Enum.reject(socket.assigns.assignment_rows, &(&1["key"] == key))

    {:noreply,
     assign(socket, assignment_rows: rows, assignments_dirty: true, assignment_error: nil)}
  end

  def handle_event("validate_assignments", %{"assignments" => params}, socket)
      when is_map(params) do
    {:noreply, retain_assignments(socket, params)}
  end

  def handle_event("save_assignments", params, socket) do
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

      {socket, key} = Submission.prepare(socket, "set_zone_assignments", payload)

      case Domain.mutate("set_zone_assignments", payload, "operator", key) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> load_assignments(socket.assigns.zone["id"])
           |> put_flash(:info, "Worker assignments saved. No target was prepared or delivered.")}

        {:error, error} ->
          {:noreply, assign(socket, assignment_error: error[:message] || error["message"])}
      end
    else
      {:noreply,
       assign(socket, assignment_error: "Save and confirm a Zone version before assigning it.")}
    end
  end

  def handle_event("refresh_assignments", _params, socket) do
    if socket.assigns.zone do
      {:noreply, load_assignments(socket, socket.assigns.zone["id"])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_record", _params, socket) do
    rows = socket.assigns.rows ++ [new_record("A")]
    {:noreply, assign_form(socket, socket.assigns.form.params, rows)}
  end

  def handle_event("remove_record", %{"index" => index}, socket) do
    rows =
      socket.assigns.rows
      |> Enum.with_index()
      |> Enum.reject(fn {_row, ordinal} -> to_string(ordinal) == index end)
      |> Enum.map(&elem(&1, 0))

    {:noreply, assign_form(socket, socket.assigns.form.params, rows)}
  end

  def handle_event("save", %{"zone" => params}, socket) do
    rows = record_rows(params)
    payload = %{"name" => params["name"], "records" => Enum.map(rows, &normalize_record/1)}
    zone = socket.assigns.zone
    operation = if zone, do: "update_zone", else: "create_zone"

    payload =
      if zone,
        do: Map.merge(payload, %{"id" => zone["id"], "expected_revision" => zone["revision"]}),
        else: payload

    {socket, key} = Submission.prepare(socket, operation, payload)

    case Domain.mutate(operation, payload, "operator", key) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Zone draft saved. Confirm a version before assigning it to a service."
         )
         |> push_patch(to: "#{socket.assigns.base_path}/#{saved["id"]}/edit")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign_form(params, rows)
         |> put_flash(:error, error.message)}
    end
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

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    case socket.assigns.deleting do
      %{"id" => ^id} = zone ->
        payload = %{"id" => id, "expected_revision" => zone["revision"]}
        {socket, key} = Submission.prepare(socket, "delete_zone", payload)

        case Domain.mutate("delete_zone", payload, "operator", key) do
          {:ok, _result} ->
            socket =
              socket
              |> assign(zones: Domain.list_zones(), deleting: nil)
              |> put_flash(:info, "Zone draft deleted. Historical versions are retained.")

            socket =
              if socket.assigns.zone && socket.assigns.zone["id"] == id,
                do: push_patch(socket, to: socket.assigns.base_path),
                else: socket

            {:noreply, socket}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, error.message)}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Select a Zone and confirm its deletion first.")}
    end
  end

  def handle_event("confirm_delete", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select a Zone and confirm its deletion first.")}
  end

  def handle_event("confirm_zone", %{"id" => id}, socket) do
    zone = cached_zone(socket, id)

    if zone do
      payload = %{"id" => id, "expected_revision" => zone["revision"]}
      {socket, key} = Submission.prepare(socket, "confirm_zone", payload)

      case Domain.mutate("confirm_zone", payload, "operator", key) do
        {:ok, _result} ->
          socket =
            socket
            |> assign(:zones, Domain.list_zones())
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
      {:noreply, put_flash(socket, :error, "Zone is no longer available. Reload the page.")}
    end
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

  defp csv_cell(value) do
    value = if Regex.match?(~r/\A(?:[\t\r\n]|\s*[=+\-@])/u, value), do: "'" <> value, else: value

    if String.contains?(value, [",", "\"", "\r", "\n"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end

  defp load_zone(socket, zone) do
    preserve_assignments =
      socket.assigns.assignment_zone_id == zone["id"] && socket.assigns.assignments_dirty

    socket =
      socket
      |> assign(
        page_title: "Edit DNS Zone",
        zone: zone,
        versions: Domain.list_versions(zone["id"])
      )
      |> assign_form(%{"name" => zone["name"]}, zone["records"])

    if preserve_assignments, do: socket, else: load_assignments(socket, zone["id"])
  end

  defp load_assignments(socket, zone_id) do
    case Domain.get_zone_assignments(zone_id) do
      {:ok, snapshot} ->
        rows = Enum.map(snapshot["assignments"], &Map.put(&1, "key", &1["id"]))

        assign(socket,
          workers: assignment_workers(),
          assignment_zone_id: zone_id,
          assignment_rows: rows,
          assignment_token: snapshot["assignment_token"],
          assignment_worker_revisions: snapshot["worker_revisions"],
          assignments_dirty: false,
          assignment_error: nil
        )

      {:error, error} ->
        assign(socket, assignment_error: error[:message] || error["message"])
    end
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
      assign(socket,
        assignment_zone_id: nil,
        assignment_rows: [],
        assignment_token: nil,
        assignment_worker_revisions: %{},
        assignments_dirty: false,
        assignment_error: nil
      )

  defp dns_services(worker), do: Enum.filter(worker["services"], &(&1["type"] == "dns"))

  defp assignment_workers do
    Enum.map(Domain.list_workers(), fn summary ->
      {:ok, worker} = Domain.get_worker(summary["id"])
      worker
    end)
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
    assigns = assign(assigns, :visible_zones, visible_zones(assigns.zones, assigns.filter))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      servers={Enum.map(@workers, &%{id: &1["id"], name: &1["name"]})}
    >
      <h1>{@page_title}</h1>
      <p class="management-help">
        Global reusable Zone library: Management-owned DNS drafts and immutable versions, not View-owned content. Actual Worker runtime state is unknown. SOA, NS and A records are supported by the current shared contract.
      </p>
      <p class="management-help">
        Only authoritative Zones are supported. Forward, stub, cloud and additional record types remain pending. Runtime query counts are unavailable.
      </p>
      <div class="management-actions">
        <.link patch={@base_path} class="btn btn-ghost">Zones</.link>
        <.link patch={@base_path <> "/new"} class="btn btn-primary">New Zone</.link>
        <.link navigate={@base_path <> "/import"} class="btn btn-ghost">Import Zone</.link>
        <button id="zone-refresh" class="btn btn-ghost" phx-click="refresh">Refresh</button>
        <button id="zone-export" class="btn btn-ghost" phx-hook="CsvDownload" phx-click="export_csv">Export filtered CSV</button>
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
      <p id="zone-count" data-displayed={length(@visible_zones)} data-total={length(@zones)}>
        {length(@visible_zones)} of {length(@zones)} Zones shown.
      </p>
      <.card :if={@live_action == :index} title="DNS Zones">
        <p :if={@zones == []}>No zones configured. Create a Zone without registering a Worker.</p>
        <p :if={@zones != [] and @visible_zones == []}>No Zone names match this filter.</p>
        <div class="management-records">
          <table id="zones-table" class="table table-striped">
            <thead>
              <tr>
                <th>Zone</th><th>Draft revision</th><th>Records</th><th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={zone <- @visible_zones} id={"zone-#{zone["id"]}"}>
                <td>{zone["name"]}</td><td>{zone["revision"]}</td><td>{length(zone["records"])}</td>
                <td>
                  <div class="management-actions">
                    <.link patch={"#{@base_path}/#{zone["id"]}/edit"} class="btn btn-ghost">Edit</.link>
                    <.link navigate={"#{@base_path}/#{zone["id"]}/records"} class="btn btn-ghost">Records</.link>
                    <button
                      class="btn btn-primary"
                      phx-click="confirm_zone"
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
      <.card :if={@live_action in [:new, :edit]} title="Zone Draft">
        <.form for={@form} id="zone-form" phx-change="validate" phx-submit="save">
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
            <.link patch={@base_path} class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
        <div :if={@zone} class="management-actions">
          <.link navigate={"#{@base_path}/#{@zone["id"]}/records"} class="btn btn-ghost">Records</.link>
          <button
            class="btn btn-primary"
            phx-click="confirm_zone"
            phx-disable-with="Confirming…"
            phx-value-id={@zone["id"]}
          >Confirm Version</button>
          <button
            class="btn btn-error"
            phx-click="delete_zone"
            phx-value-id={@zone["id"]}
          >Delete</button>
        </div>
      </.card>
      <.card :if={@zone} title="Worker assignments">
        <p class="management-help">
          Zone data is global. Assign a confirmed version to each logical Worker and DNS Service; assignments do not report execution.
        </p>
        <p :if={@versions == []}>
          Confirm a version before assigning this Zone. The draft remains editable.
        </p>
        <p :if={@assignment_error} id="zone-assignment-error" class="alert alert-error" role="alert">
          {@assignment_error}
        </p>
        <div class="management-actions">
          <button
            :for={worker <- @workers}
            class="btn btn-secondary"
            phx-click="add_assignment_worker"
            phx-value-id={worker["id"]}
            disabled={@versions == [] || dns_services(worker) == []}
          >
            Assign {worker["name"]} ({worker["id"]})
          </button>
        </div>
        <p :if={@workers == []}>
          No logical Workers are registered. Zone drafts and versions remain global.
        </p>
        <p :for={worker <- @workers} :if={dns_services(worker) == []}>
          {worker["name"]} has no DNS Services.
          <.link navigate={ServicePaths.server_path(worker["id"], :dashboard)}>Configure a DNS Service</.link>
        </p>
        <form
          id="zone-assignments-form"
          phx-change="validate_assignments"
          phx-submit="save_assignments"
        >
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
              <select class="select" name={"assignments[#{row["key"]}][resource_version_id]"} required>
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
              disabled={@versions == [] && @assignment_rows == []}
            >Save assignments</button>
            <button
              type="button"
              class="btn btn-secondary"
              phx-click="refresh_assignments"
              data-confirm={
                if @assignments_dirty,
                  do: "Discard unsaved assignment changes and reload the assignment set?",
                  else: nil
              }
            >Reload assignment set</button>
          </div>
        </form>
      </.card>
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
              phx-disable-with="Deleting…"
              phx-value-id={@deleting["id"]}
            >Confirm Delete</button>
            <button id="zone-cancel-delete" class="btn btn-ghost" phx-click="cancel_delete">Cancel Delete</button>
          </div>
        </div>
      </.card>
      <.card :if={@zone} title="Immutable Versions">
        <p :if={@versions == []}>
          No confirmed versions. Saving a draft does not change an assigned version.
        </p>
        <div class="management-records">
          <table id="zone-versions" class="table">
            <thead>
              <tr>
                <th>Version</th><th>Source revision</th><th>Digest</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={version <- @versions}>
                <td>{version["version"]}</td><td>{version["source_revision"]}</td><td>
                  {version["digest"]}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
