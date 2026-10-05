defmodule YellowDog.ManagementUI.RecordsLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.ConfigSpec
  alias YellowDog.Management.Domain
  alias YellowDog.ManagementUI.DnsRecordExports
  alias YellowDog.ManagementUI.Hooks.CurrentPath

  @max_bulk_bytes 1_048_576
  @numeric_fields ~w(serial refresh retry expire minimum)
  @soa_fields ~w(mname rname serial refresh retry expire minimum)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Records",
       workers: Domain.list_workers(),
       zone: nil,
       zone_id: nil,
       server_id: nil,
       rr_index: nil,
       filter: "",
       type_filter: "all",
       stale_editor: false,
       scope_error: nil,
       error: nil,
       form: to_form(new_record("A"), as: "record"),
       bulk_preview: nil,
       bulk_form: to_form(%{"records" => ""}, as: "bulk")
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    path_params = CurrentPath.route_path_params(socket, uri)
    server_id = path_params["server_id"]
    zone_id = path_params["zone_id"]

    zone_path =
      if server_id,
        do: "/server/#{segment(server_id)}/dns/zones/#{segment(zone_id)}",
        else: "/management/zones/#{segment(zone_id)}"

    socket =
      assign(socket,
        workers: Domain.list_workers(),
        server_id: server_id,
        zone_id: zone_id,
        zone_path: zone_path,
        records_path: zone_path <> "/records",
        zone: nil,
        rr_index: nil,
        stale_editor: false,
        scope_error: nil,
        error: nil,
        form: to_form(new_record("A"), as: "record"),
        bulk_preview: nil,
        bulk_form: to_form(%{"records" => ""}, as: "bulk")
      )

    with :ok <- worker_scope(server_id),
         {:ok, zone} <- Domain.get_zone(zone_id),
         {:ok, index} <- route_index(socket.assigns.live_action, path_params, zone) do
      form_record =
        if is_integer(index), do: Enum.at(zone["records"], index), else: new_record("A")

      {:noreply,
       assign(socket, zone: zone, rr_index: index, form: to_form(form_record, as: "record"))}
    else
      {:error, %{message: message}} -> {:noreply, assign(socket, :scope_error, message)}
      {:error, message} -> {:noreply, assign(socket, :scope_error, message)}
    end
  end

  @impl true
  def handle_event("filter", %{"filter" => filter, "type" => type}, socket)
      when is_binary(filter) and byte_size(filter) <= 512 and type in ~w(all SOA NS A) do
    if String.valid?(filter) do
      {:noreply, assign(socket, filter: filter, type_filter: type, error: nil)}
    else
      {:noreply, assign(socket, :error, "Invalid record filter.")}
    end
  end

  def handle_event("filter", _params, socket),
    do: {:noreply, assign(socket, :error, "Invalid record filter.")}

  def handle_event("refresh", _params, socket) do
    with :ok <- worker_scope(socket.assigns.server_id),
         {:ok, zone} <- Domain.get_zone(socket.assigns.zone_id) do
      if (socket.assigns.live_action != :index and socket.assigns.zone) &&
           zone["revision"] != socket.assigns.zone["revision"] do
        {:noreply, assign(socket, stale_editor: true, bulk_preview: nil, error: stale_message())}
      else
        socket = assign(socket, workers: Domain.list_workers(), error: nil)

        socket =
          if socket.assigns.live_action == :index, do: assign(socket, zone: zone), else: socket

        {:noreply, socket}
      end
    else
      {:error, error} ->
        message = if is_map(error), do: error.message, else: error
        {:noreply, assign(socket, zone: nil, bulk_preview: nil, scope_error: message)}
    end
  end

  def handle_event("export_csv", _params, socket) do
    with :ok <- mutation_scope(socket),
         :ok <- action_allowed(socket, [:index]) do
      records =
        socket.assigns.zone
        |> visible_records(socket.assigns.filter, socket.assigns.type_filter)
        |> Enum.map(fn {record, _ordinal} -> record end)

      {:noreply,
       push_event(socket, "download_csv", %{
         content: DnsRecordExports.csv(records),
         filename: "dns_records_#{socket.assigns.zone["id"]}.csv"
       })}
    else
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("export_bind", _params, socket) do
    with :ok <- mutation_scope(socket),
         :ok <- action_allowed(socket, [:index]) do
      {:noreply,
       push_event(socket, "download_text", %{
         content: DnsRecordExports.bind(socket.assigns.zone),
         filename: "dns_zone_#{socket.assigns.zone["id"]}.zone"
       })}
    else
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("validate", %{"record" => params}, socket) when is_map(params) do
    if params["type"] in ~w(SOA NS A) do
      defaults = new_record(params["type"])
      data = if is_map(params["data"]), do: params["data"], else: %{}
      data = Map.merge(defaults["data"], Map.take(data, data_fields(params["type"])))
      {:noreply, assign(socket, :form, record_form(Map.put(params, "data", data)))}
    else
      {:noreply, assign(socket, :error, "Only SOA, NS and A records are supported.")}
    end
  end

  def handle_event("save", %{"record" => params}, socket) when is_map(params) do
    socket = assign(socket, :form, record_form(params))

    with :ok <- mutation_scope(socket),
         :ok <- action_allowed(socket, [:new, :edit]),
         {:ok, record} <- single_record(params, socket.assigns.zone["name"]) do
      records = socket.assigns.zone["records"]

      records =
        case socket.assigns.live_action do
          :new -> records ++ [record]
          :edit -> List.replace_at(records, socket.assigns.rr_index, record)
        end

      persist(socket, records)
    else
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("preview_bulk", %{"bulk" => %{"records" => input}}, socket)
      when is_binary(input) do
    socket =
      assign(socket,
        bulk_form: to_form(%{"records" => input}, as: "bulk"),
        bulk_preview: nil
      )

    with :ok <- mutation_scope(socket),
         :ok <- action_allowed(socket, [:bulk]),
         {:ok, preview} <- bulk_preview(socket.assigns.zone, input) do
      {:noreply, assign(socket, bulk_preview: preview, error: nil)}
    else
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("preview_bulk", _params, socket) do
    {:noreply, assign(socket, bulk_preview: nil, error: "Invalid bulk preview request.")}
  end

  def handle_event("save_bulk", %{"bulk" => %{"records" => input}}, socket)
      when is_binary(input) do
    socket = assign(socket, :bulk_form, to_form(%{"records" => input}, as: "bulk"))

    with :ok <- mutation_scope(socket),
         :ok <- action_allowed(socket, [:bulk]),
         %{source: ^input, revision: revision, content: content} <- socket.assigns.bulk_preview,
         true <- revision == socket.assigns.zone["revision"] do
      persist(socket, content["records"])
    else
      {:error, message} ->
        {:noreply, assign(socket, bulk_preview: nil, error: message)}

      _unreviewed ->
        {:noreply,
         assign(socket,
           bulk_preview: nil,
           error: "Review a valid preview of the current bulk input before appending records."
         )}
    end
  end

  def handle_event("delete_record", %{"rr_index" => ordinal}, socket) do
    with :ok <- mutation_scope(socket),
         :ok <- action_allowed(socket, [:index]),
         {:ok, index} <- ordinal(ordinal, length(socket.assigns.zone["records"])) do
      persist(socket, List.delete_at(socket.assigns.zone["records"], index))
    else
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, assign(socket, :error, "Invalid record action or form data.")}
  end

  defp persist(socket, records) do
    zone = socket.assigns.zone

    params = %{
      "id" => zone["id"],
      "expected_revision" => zone["revision"],
      "name" => zone["name"],
      "records" => records
    }

    case Domain.mutate("update_zone", params, "operator", Ecto.UUID.generate()) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(zone: saved, bulk_preview: nil, error: nil)
         |> put_flash(
           :info,
           "Zone draft records saved. Immutable versions and Worker runtime are unchanged."
         )
         |> push_patch(to: socket.assigns.records_path)}

      {:error, error} ->
        socket =
          if socket.assigns.live_action == :bulk and error.code == "revision_conflict",
            do: assign(socket, bulk_preview: nil, stale_editor: true),
            else: socket

        {:noreply, assign(socket, :error, error.message <> error_details(error))}
    end
  end

  defp error_details(%{details: details}) when map_size(details) > 0,
    do: ": " <> Jason.encode!(details)

  defp error_details(_error), do: ""

  defp mutation_scope(%{assigns: %{scope_error: message}}) when is_binary(message),
    do: {:error, message}

  defp mutation_scope(%{assigns: %{zone: nil}}), do: {:error, "Zone is unavailable."}
  defp mutation_scope(%{assigns: %{stale_editor: true}}), do: {:error, stale_message()}
  defp mutation_scope(socket), do: worker_scope(socket.assigns.server_id)

  defp stale_message,
    do: "Zone draft changed. Return to Records and reopen the editor before saving."

  defp visible_records(nil, _filter, _type), do: []

  defp visible_records(zone, filter, type) do
    owner_filter = String.downcase(filter)

    zone["records"]
    |> Enum.with_index()
    |> Enum.filter(fn {record, _ordinal} ->
      String.contains?(String.downcase(record["name"]), owner_filter) and
        (type == "all" or record["type"] == type)
    end)
  end

  defp worker_scope(nil), do: :ok

  defp worker_scope(server_id) do
    case Domain.get_worker(server_id) do
      {:ok, _worker} ->
        :ok

      {:error, _error} ->
        {:error,
         "Selected Worker does not exist. Open Records from a registered Worker or Management."}
    end
  end

  defp action_allowed(socket, actions) do
    if socket.assigns.live_action in actions,
      do: :ok,
      else: {:error, "Record action does not match this route."}
  end

  defp route_index(:edit, params, zone), do: ordinal(params["rr_index"], length(zone["records"]))
  defp route_index(action, _params, _zone) when action in [:index, :new, :bulk], do: {:ok, nil}
  defp route_index(_action, _params, _zone), do: {:error, "Unknown Records route."}

  defp ordinal(value, count) when is_binary(value) and byte_size(value) <= 10 do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) do
      index = String.to_integer(value)

      if index < count,
        do: {:ok, index},
        else: {:error, "Invalid record ordinal: record is out of range."}
    else
      {:error, "Invalid record ordinal: use a nonnegative decimal index."}
    end
  end

  defp ordinal(_value, _count),
    do: {:error, "Invalid record ordinal: use a nonnegative decimal index."}

  defp single_record(%{"type" => type, "data" => data} = params, apex)
       when type in ["SOA", "NS", "A"] and is_map(data) do
    data =
      Map.new(Map.take(data, data_fields(type)), fn {field, value} ->
        {field, if(numeric_field?(field), do: integer(value), else: value)}
      end)

    {:ok,
     %{
       "name" => owner(params["name"], apex),
       "type" => type,
       "ttl" => integer(params["ttl"]),
       "data" => data
     }}
  end

  defp single_record(_params, _apex),
    do: {:error, "Only SOA, NS and A records with structured data are supported."}

  defp owner(value, apex) when value in ["", "@"], do: apex

  defp owner(value, apex) when is_binary(value) do
    if String.ends_with?(value, "."), do: value, else: value <> "." <> apex
  end

  defp owner(value, _apex), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp integer(value), do: value

  defp bulk_records(input) when is_binary(input) and byte_size(input) <= @max_bulk_bytes do
    case Jason.decode(input) do
      {:ok, records} when is_list(records) and records != [] ->
        if Enum.all?(records, &is_map/1),
          do: {:ok, records},
          else: {:error, "Bulk JSON must be a nonempty array of canonical record objects."}

      _ ->
        {:error, "Bulk JSON must be a valid nonempty array of canonical record objects."}
    end
  end

  defp bulk_records(_input), do: {:error, "Bulk JSON must not exceed 1 MiB (1048576 bytes)."}

  defp bulk_preview(zone, input) do
    with {:ok, records} <- bulk_records(input),
         {:ok, resource} <-
           ConfigSpec.normalize_resource(%{
             "id" => zone["id"],
             "type" => "dns_zone",
             "schema_version" => 1,
             "version" => 1,
             "content" => %{"name" => zone["name"], "records" => zone["records"] ++ records}
           }) do
      existing = MapSet.new(zone["records"])
      appended = Enum.reject(resource["content"]["records"], &MapSet.member?(existing, &1))

      {:ok,
       %{
         source: input,
         revision: zone["revision"],
         content: resource["content"],
         records: appended,
         existing_count: length(zone["records"]),
         total_count: length(resource["content"]["records"]),
         counts: appended |> Enum.frequencies_by(& &1["type"]) |> Enum.sort()
       }}
    else
      {:error, errors} when is_list(errors) ->
        {:error,
         "Invalid bulk candidate: " <>
           Enum.map_join(errors, "; ", fn error ->
             Enum.map_join(error.path, ".", &to_string/1) <> ": " <> error.message
           end)}

      {:error, message} ->
        {:error, message}
    end
  end

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

    %{"name" => "@", "type" => type, "ttl" => 300, "data" => data}
  end

  defp data_fields("SOA"), do: @soa_fields
  defp data_fields("NS"), do: ["host"]
  defp data_fields("A"), do: ["address"]
  defp data_fields(_type), do: []
  defp numeric_field?(field), do: field in @numeric_fields

  defp record_form(params) do
    data = if is_map(params["data"]), do: params["data"], else: %{}

    fields =
      Map.new(Map.take(params, ~w(name type ttl)), fn {field, value} ->
        {field, input_value(value)}
      end)

    data = Map.new(data, fn {field, value} -> {field, input_value(value)} end)
    to_form(Map.put(fields, "data", data), as: "record")
  end

  defp input_value(value) when is_binary(value) or is_integer(value), do: value
  defp input_value(_value), do: nil
  defp segment(value) when is_binary(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp segment(_value), do: ""

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :visible_records,
        visible_records(assigns.zone, assigns.filter, assigns.type_filter)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      servers={Enum.map(@workers, &%{id: &1["id"], name: &1["name"]})}
    >
      <h1>DNS Records</h1>
      <p class="management-help">
        SOA, NS and A only. Other original Console record types are not migrated. These are Management-owned drafts; actual Worker runtime state is unknown.
      </p>
      <p :if={@scope_error} id="record-scope-error" role="alert">{@scope_error}</p>
      <p :if={@error} id="record-error" role="alert">{@error}</p>
      <div :if={@zone}>
        <h2>{@zone["name"]}</h2>
        <p>
          Draft revision {@zone["revision"]}. Confirmed immutable versions are unchanged by record edits.
        </p>
        <div class="management-actions">
          <.link patch={@records_path} class="btn btn-ghost">Records</.link>
          <.link patch={@records_path <> "/new"} class="btn btn-primary">New Record</.link>
          <.link patch={@records_path <> "/bulk"} class="btn btn-ghost">Bulk Add</.link>
          <.link navigate={@zone_path <> "/edit"} class="btn btn-ghost">Zone Draft</.link>
          <button id="record-refresh" type="button" class="btn btn-ghost" phx-click="refresh">Refresh</button>
        </div>
        <.card :if={@live_action == :index} title="Records">
          <.form
            for={to_form(%{"filter" => @filter, "type" => @type_filter})}
            id="record-filter-form"
            phx-change="filter"
            phx-submit="filter"
          >
            <label class="management-field"><span>Filter owner</span><input
              id="record-owner-filter"
              class="input"
              name="filter"
              value={@filter}
              maxlength="512"
            /></label>
            <label class="management-field"><span>Record type</span><select
              id="record-type-filter"
              name="type"
              class="select"
            >
              <option :for={type <- ~w(all SOA NS A)} value={type} selected={type == @type_filter}>
                {if type == "all", do: "All types", else: type}
              </option>
            </select></label>
            <button type="submit" class="btn btn-ghost">Filter</button>
          </.form>
          <p id="record-count">
            Showing {length(@visible_records)} of {length(@zone["records"])} records.
          </p>
          <div class="management-actions">
            <button
              id="record-export-csv"
              type="button"
              class="btn btn-ghost"
              phx-hook="CsvDownload"
              phx-click="export_csv"
            >Export Filtered CSV</button>
            <button
              id="record-export-bind"
              type="button"
              class="btn btn-ghost"
              phx-hook="TextDownload"
              phx-click="export_bind"
            >Export Full Zone BIND</button>
          </div>
          <p class="management-help">
            CSV includes the displayed records. BIND includes the full valid SOA/NS/A Zone draft, regardless of filters; it is not a Worker runtime snapshot.
          </p>
          <div class="management-records">
            <table id="records-table" class="table table-striped">
              <thead>
                <tr>
                  <th>Name</th><th>Type</th><th>TTL</th><th>Data</th><th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{record, index} <- @visible_records}
                  id={"record-#{index}"}
                  data-rr-index={index}
                >
                  <td>{record["name"]}</td><td>{record["type"]}</td><td>{record["ttl"]}</td><td>
                    <code>{Jason.encode!(record["data"])}</code>
                  </td>
                  <td>
                    <div class="management-actions">
                      <.link patch={"#{@records_path}/#{index}/edit"} class="btn btn-ghost">Edit</.link>
                      <button
                        class="btn btn-error"
                        phx-click="delete_record"
                        phx-value-rr_index={index}
                        data-confirm="Delete this record from the draft? The Zone must remain valid."
                      >Delete</button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@visible_records == []} id="record-empty">No records match these filters.</p>
        </.card>
        <.card
          :if={@live_action in [:new, :edit]}
          title={if @live_action == :new, do: "New Record", else: "Edit Record"}
        >
          <.form for={@form} id="record-form" phx-change="validate" phx-submit="save">
            <label class="management-field"><span>Owner name</span><input
              class="input"
              name="record[name]"
              value={@form[:name].value}
            /></label>
            <p class="management-help">
              Use @ or an empty name for the apex, a relative owner such as www, or a fully qualified owner ending with a dot.
            </p>
            <label class="management-field"><span>Type</span><select
              class="select"
              name="record[type]"
            ><option :for={type <- ~w(SOA NS A)} value={type} selected={type == @form[:type].value}>
              {type}
            </option></select></label>
            <label class="management-field"><span>TTL (seconds)</span><input
              class="input"
              type="number"
              min="0"
              name="record[ttl]"
              value={@form[:ttl].value}
              required
            /></label>
            <label :for={field <- data_fields(@form[:type].value)} class="management-field">
              <span>{field}</span><input
                class="input"
                type={if numeric_field?(field), do: "number", else: "text"}
                min={if numeric_field?(field), do: "0"}
                name={"record[data][#{field}]"}
                value={(@form[:data].value || %{})[field]}
                required
              />
            </label>
            <div class="management-actions">
              <button
                class="btn btn-primary"
                type="submit"
                disabled={@stale_editor}
                phx-disable-with="Saving…"
              >Save Record</button><.link
                patch={@records_path}
                class="btn btn-ghost"
              >Cancel</.link>
            </div>
          </.form>
        </.card>
        <.card :if={@live_action == :bulk} title="Bulk Add Records">
          <p class="management-help">
            Preview and append a nonempty JSON array of canonical record objects, at most 1 MiB. Use fully qualified names and numeric TTL/SOA values. The complete candidate Zone is validated without writes; confirm only the reviewed input. BIND bulk import remains unavailable.
          </p>
          <pre id="bulk-record-example"><code>{Jason.encode!([%{"name" => "www." <> @zone["name"], "type" => "A", "ttl" => 300, "data" => %{"address" => "192.0.2.20"}}], pretty: true)}</code></pre>
          <.form
            for={@bulk_form}
            id="bulk-record-form"
            phx-change="preview_bulk"
            phx-submit="save_bulk"
          >
            <label class="management-field"><span>Records JSON</span><textarea
              class="textarea"
              name="bulk[records]"
              rows="12"
              maxlength="1048576"
              phx-debounce="500"
              required
            >{@bulk_form[:records].value}</textarea></label>
            <section :if={@bulk_preview} id="bulk-record-preview">
              <h2>Bulk Preview</h2>
              <p id="bulk-record-count">
                Append {length(@bulk_preview.records)} records to {@bulk_preview.existing_count} existing records; total {@bulk_preview.total_count}. Draft revision {@bulk_preview.revision}
              </p>
              <ul id="bulk-record-types">
                <li :for={{type, count} <- @bulk_preview.counts}>{type}: {count}</li>
              </ul>
              <div class="management-records">
                <table id="bulk-record-preview-table" class="table table-striped">
                  <thead>
                    <tr>
                      <th>Name</th><th>Type</th><th>TTL</th><th>Data</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={record <- @bulk_preview.records}>
                      <td>{record["name"]}</td><td>{record["type"]}</td><td>{record["ttl"]}</td><td>
                        <code>{Jason.encode!(record["data"])}</code>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <p class="management-help">
                Preview is draft content only. Appending does not publish an immutable version or apply Worker configuration.
              </p>
            </section>
            <div class="management-actions">
              <button
                id="bulk-record-save"
                class="btn btn-primary"
                type="submit"
                disabled={@stale_editor or is_nil(@bulk_preview)}
                phx-disable-with="Appending…"
              >Append Records</button><.link
                patch={@records_path}
                class="btn btn-ghost"
              >Cancel</.link>
            </div>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
