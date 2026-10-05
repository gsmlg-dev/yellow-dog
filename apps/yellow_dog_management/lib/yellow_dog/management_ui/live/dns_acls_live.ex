defmodule YellowDog.ManagementUI.DnsAclsLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Countries, DnsAcls, Domain}
  alias YellowDog.ManagementUI.DnsRulesText
  alias YellowDog.ManagementUI.Hooks.CurrentPath

  @max_rules_bytes 262_144
  @presets ~w(any none localhost localnets)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS ACLs",
       workers: Domain.list_workers(),
       worker: nil,
       services: [],
       service: nil,
       acls: [],
       editing: nil,
       deleting: nil,
       scope_params: %{},
       error: nil,
       field_errors: %{},
       filter: "",
       country_search: "",
       selected_countries: [],
       country_action: "allow",
       preset: "",
       form: new_form()
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    params = CurrentPath.route_path_params(socket, uri)
    {:noreply, socket |> load(params) |> reset_form()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load(socket.assigns.scope_params) |> reset_form()}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> clear_editor() |> reset_form()}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case scoped_acl(socket, id) do
      {:ok, acl} ->
        {:noreply,
         socket
         |> clear_editor()
         |> assign(editing: acl, form: acl_form(acl))
         |> reset_form()}

      {:error, error} ->
        failure(socket, error)
    end
  end

  def handle_event("validate", %{"acl" => params} = payload, socket) when is_map(params) do
    {:noreply, socket |> retain_fields(params, payload) |> validate_form()}
  end

  def handle_event("filter", %{"filter" => filter}, socket)
      when is_binary(filter) and byte_size(filter) <= 512 do
    {:noreply, assign(socket, filter: filter)}
  end

  def handle_event("toggle_country", %{"code" => code}, socket) when is_binary(code) do
    if Countries.valid?(code) do
      selected = socket.assigns.selected_countries
      updated = if code in selected, do: List.delete(selected, code), else: [code | selected]
      {:noreply, assign(socket, selected_countries: Enum.sort(updated), error: nil)}
    else
      failure(socket, "Unknown ISO country code")
    end
  end

  def handle_event("clear_country_search", _params, socket) do
    {:noreply, assign(socket, country_search: "")}
  end

  def handle_event(
        "save",
        %{"operation" => "append_countries", "acl" => params} = payload,
        socket
      )
      when is_map(params) do
    socket = retain_fields(socket, params, payload)

    with :ok <- selected_scope(socket),
         true <- socket.assigns.country_action in ~w(allow deny),
         [_country | _rest] <- socket.assigns.selected_countries,
         text when is_binary(text) <- params["rules"] do
      separator = if text == "" or String.ends_with?(text, "\n"), do: "", else: "\n"

      rule =
        socket.assigns.country_action <>
          " countries " <> Enum.join(socket.assigns.selected_countries, ", ")

      fields = Map.put(form_fields(socket), "rules", text <> separator <> rule)

      {:noreply,
       socket
       |> retain_fields(fields, payload)
       |> assign(selected_countries: [])
       |> validate_form()}
    else
      {:error, error} -> failure(socket, error)
      _ -> failure(socket, "Select countries and an allow/deny action before appending")
    end
  end

  def handle_event("save", %{"operation" => "apply_preset", "acl" => params} = payload, socket)
      when is_map(params) do
    socket = retain_fields(socket, params, payload)

    with :ok <- selected_scope(socket),
         text when is_binary(text) <- params["rules"],
         true <- String.trim(text) == "",
         {:ok, rules} <- DnsAcls.preset_rules(socket.assigns.preset) do
      {:noreply,
       socket
       |> retain_fields(Map.put(form_fields(socket), "rules", format_rules(rules)), payload)
       |> validate_form()}
    else
      {:error, error} ->
        failure(socket, error)

      _ ->
        failure(
          socket,
          "Presets apply only to an empty rules editor; existing rules were retained"
        )
    end
  end

  def handle_event("save", %{"operation" => _unknown}, socket),
    do: failure(socket, "Invalid editor operation")

  def handle_event("save", %{"acl" => params}, socket) when is_map(params) do
    socket = socket |> retain_fields(params, %{}) |> validate_form()

    with :ok <- selected_scope(socket),
         {:ok, fields} <- validated_fields(form_fields(socket)) do
      fields =
        Map.merge(fields, scope_fields(socket))

      {operation, fields} =
        case socket.assigns.editing do
          nil ->
            {"create_dns_acl", fields}

          acl ->
            {"update_dns_acl",
             Map.merge(fields, %{"id" => acl["id"], "expected_revision" => acl["revision"]})}
        end

      case Domain.mutate(operation, fields, "operator", Ecto.UUID.generate()) do
        {:ok, _acl} ->
          {:noreply,
           socket
           |> load(socket.assigns.scope_params)
           |> clear_flash()
           |> put_flash(:info, "Desired ACL saved; not enforced/exported")
           |> reset_form()}

        {:error, error} ->
          failure(socket, error)
      end
    else
      {:error, error} -> failure(socket, error)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case scoped_acl(socket, id) do
      {:ok, acl} -> {:noreply, assign(socket, deleting: acl, error: nil)}
      {:error, error} -> failure(socket, error)
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, deleting: nil, error: nil)}
  end

  def handle_event("export_csv", _params, socket) do
    with :ok <- selected_scope(socket),
         {:ok, acls} <-
           Domain.list_dns_acls(socket.assigns.worker["id"], socket.assigns.service["id"]) do
      rows =
        Enum.map_join(acls, "", fn acl ->
          [acl["name"], acl["description"], format_rules(acl["rules"])]
          |> Enum.map_join(",", &csv_cell/1)
          |> Kernel.<>("\r\n")
        end)

      {:noreply,
       push_event(socket, "download_csv", %{
         content: "Name,Description,Rules\r\n" <> rows,
         filename: "dns_acls_#{socket.assigns.worker["id"]}_#{socket.assigns.service["id"]}.csv"
       })}
    else
      {:error, error} -> failure(socket, error)
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    with :ok <- selected_scope(socket),
         %{"id" => ^id} = acl <- socket.assigns.deleting do
      fields =
        Map.merge(scope_fields(socket), %{"id" => id, "expected_revision" => acl["revision"]})

      case Domain.mutate("delete_dns_acl", fields, "operator", Ecto.UUID.generate()) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> load(socket.assigns.scope_params)
           |> clear_flash()
           |> put_flash(:info, "Desired ACL deleted; not enforced/exported")
           |> reset_form()}

        {:error, error} ->
          failure(socket, error)
      end
    else
      {:error, error} -> failure(socket, error)
      _ -> failure(socket, "Select an ACL and confirm its deletion first")
    end
  end

  def handle_event(_event, _params, socket), do: failure(socket, "Invalid ACL action")

  defp load(socket, params) do
    socket =
      assign(socket,
        workers: Domain.list_workers(),
        worker: nil,
        service: nil,
        services: [],
        acls: [],
        editing: nil,
        deleting: nil,
        error: nil,
        field_errors: %{},
        selected_countries: [],
        country_search: "",
        country_action: "allow",
        preset: "",
        scope_params: params,
        form: new_form()
      )

    with true <- ServicePaths.valid_server_id?(params["server_id"]),
         {:ok, worker} <- Domain.get_worker(params["server_id"]) do
      services = Enum.filter(worker["services"], &(&1["type"] == "dns"))
      socket = assign(socket, worker: worker, services: services)

      case params do
        %{"service_id" => service_id} -> load_service(socket, service_id)
        _ -> socket
      end
    else
      false -> assign(socket, error: "Invalid Worker identifier")
      {:error, error} -> assign(socket, error: message(error))
    end
  end

  defp load_service(socket, service_id) do
    with {:ok, id} <- uuid(service_id),
         service when not is_nil(service) <-
           Enum.find(socket.assigns.services, &(&1["id"] == id)),
         {:ok, acls} <- Domain.list_dns_acls(socket.assigns.worker["id"], id) do
      assign(socket, service: service, acls: acls)
    else
      :error -> assign(socket, error: "Invalid DNS Service UUID")
      nil -> assign(socket, error: "DNS Service not found for the selected Worker")
      {:error, error} -> assign(socket, error: message(error))
    end
  end

  defp selected_scope(%{assigns: %{worker: worker, service: service}})
       when not is_nil(worker) and not is_nil(service),
       do: :ok

  defp selected_scope(_socket), do: {:error, "Select an existing Worker and DNS Service first"}

  defp scope_fields(socket) do
    %{"worker_id" => socket.assigns.worker["id"], "service_id" => socket.assigns.service["id"]}
  end

  defp scoped_acl(socket, id) do
    with :ok <- selected_scope(socket),
         {:ok, acl_id} <- uuid(id) do
      Domain.get_dns_acl(socket.assigns.worker["id"], socket.assigns.service["id"], acl_id)
    else
      :error -> {:error, "Invalid ACL UUID"}
      {:error, error} -> {:error, error}
    end
  end

  defp clear_editor(socket) do
    assign(socket,
      editing: nil,
      deleting: nil,
      error: nil,
      field_errors: %{},
      form: new_form(),
      selected_countries: [],
      country_search: "",
      country_action: "allow",
      preset: ""
    )
  end

  defp retain_fields(socket, params, payload) do
    fields = Map.take(params, ~w(name description rules))

    assign(socket,
      form: to_form(fields, as: "acl"),
      error: nil,
      country_search: bounded_text(payload["country_search"], socket.assigns.country_search, 256),
      country_action: Map.get(payload, "country_action", socket.assigns.country_action),
      preset: Map.get(payload, "preset", socket.assigns.preset)
    )
  end

  defp bounded_text(value, _fallback, limit) when is_binary(value) and byte_size(value) <= limit,
    do: value

  defp bounded_text(_value, fallback, _limit), do: fallback

  defp form_fields(socket), do: Map.take(socket.assigns.form.params, ~w(name description rules))

  defp validate_form(socket) do
    case validated_fields(form_fields(socket)) do
      {:ok, _fields} -> assign(socket, field_errors: %{})
      {:error, {field, error}} -> assign(socket, field_errors: %{field => error})
    end
  end

  defp validated_fields(params) do
    with true <-
           (is_binary(params["name"]) and String.valid?(params["name"]) and
              Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, params["name"])) ||
             {:error, {:name, "Name must be a 1–128 character ASCII identifier"}},
         true <-
           (is_binary(params["description"]) and String.valid?(params["description"]) and
              not String.contains?(params["description"], <<0>>) and
              length(String.to_charlist(params["description"])) <= 255) ||
             {:error,
              {:description,
               "Description must be at most 255 Unicode codepoints and contain no NUL"}},
         {:ok, rules} <- parse_rules(params["rules"]) do
      {:ok, %{"name" => params["name"], "description" => params["description"], "rules" => rules}}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp parse_rules(text), do: DnsRulesText.parse(text)

  defp uuid(value) when is_binary(value) and byte_size(value) == 36, do: Ecto.UUID.cast(value)
  defp uuid(_value), do: :error

  defp new_form, do: to_form(%{"name" => "", "description" => "", "rules" => ""}, as: "acl")

  defp acl_form(acl) do
    to_form(
      %{
        "name" => acl["name"],
        "description" => acl["description"],
        "rules" => format_rules(acl["rules"])
      },
      as: "acl"
    )
  end

  defp format_rules(rules), do: DnsRulesText.format(rules)

  defp visible_acls(acls, filter) do
    query = String.downcase(filter)

    Enum.filter(acls, fn acl ->
      Enum.any?([acl["name"], acl["description"]], &String.contains?(String.downcase(&1), query))
    end)
  end

  defp csv_cell(value) do
    value = if Regex.match?(~r/\A(?:[\t\r\n]|\s*[=+\-@])/u, value), do: "'" <> value, else: value

    if String.contains?(value, [",", "\"", "\r", "\n"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end

  defp field_value(form, field) do
    value = form[field].value
    if is_binary(value), do: value, else: ""
  end

  defp reset_form(socket), do: push_event(socket, "reset_form", %{id: "dns-acl-form"})

  defp failure(socket, error),
    do: {:noreply, socket |> clear_flash() |> assign(error: message(error))}

  defp message(error) when is_binary(error), do: error
  defp message({_field, error}), do: error
  defp message(error), do: error[:message] || error["message"]

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        visible_acls: visible_acls(assigns.acls, assigns.filter),
        countries: Countries.search(assigns.country_search),
        presets: @presets,
        max_rules_bytes: @max_rules_bytes
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      servers={Enum.map(@workers, &%{id: &1["id"], name: &1["name"]})}
    >
      <h1>DNS ACLs</h1>
      <p class="management-help">
        Management-owned desired ACLs for one explicit DNS Service. Not enforced or exported to a Worker.
        Empty rules and empty network sets are not catch-all rules. Rule order is retained as desired data, not evaluated here.
      </p>
      <div :if={@error} id="dns-acl-error" class="alert alert-error" role="alert">{@error}</div>
      <div class="management-actions">
        <button id="dns-acl-refresh" class="btn btn-secondary" phx-click="refresh">Refresh</button>
        <button
          :if={@service}
          id="dns-acl-export"
          class="btn btn-secondary"
          phx-click="export_csv"
          phx-hook="CsvDownload"
        >Export CSV — All ACLs</button>
        <.link
          :if={@worker}
          navigate={ServicePaths.server_path(@worker["id"], :dashboard)}
          class="btn btn-ghost"
        >Server Dashboard</.link>
      </div>
      <.card :if={@worker} title="Select DNS Service">
        <div id="dns-acl-service-selector" class="management-actions">
          <p>Select a DNS Service explicitly, even when only one exists.</p>
          <p :if={@services == []}>No DNS Services configured. Add one on the Server Dashboard.</p>
          <.link
            :for={service <- @services}
            patch={ServicePaths.server_path(@worker["id"], {:dns_acl_service, service["id"]})}
            data-service-id={service["id"]}
            aria-current={if @service && @service["id"] == service["id"], do: "page"}
            class="btn btn-secondary"
          >{service["instance_id"]} ({service["id"]})</.link>
        </div>
      </.card>
      <.form :if={@service} for={%{}} id="dns-acl-filter-form" phx-change="filter" phx-submit="filter">
        <label class="management-field"><span>Search name or description</span><input
          id="dns-acl-filter"
          class="input input-bordered"
          name="filter"
          value={@filter}
          maxlength="512"
          phx-debounce="300"
        /></label>
      </.form>
      <.card :if={@service} title={"Desired ACLs — #{@service["instance_id"]}"}>
        <p :if={@acls == []}>No desired ACLs for this DNS Service.</p>
        <p :if={@acls != [] && @visible_acls == []}>No ACLs match the search.</p>
        <p>
          {length(@visible_acls)} of {length(@acls)} ACLs shown. CSV exports all ACLs in this Service.
        </p>
        <div :if={@visible_acls != []} class="overflow-x-auto">
          <table id="dns-acls-table" class="table table-striped">
            <thead>
              <tr>
                <th>Name</th><th>Description</th><th>Ordered Rules</th><th>Revision</th><th>
                  Actions
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={acl <- @visible_acls}
                id={"dns-acl-#{acl["id"]}"}
                data-acl-name={acl["name"]}
                data-acl-description={acl["description"]}
                data-acl-rules={Jason.encode!(acl["rules"])}
                data-acl-revision={acl["revision"]}
              >
                <td>{acl["name"]}</td>
                <td>{acl["description"]}</td>
                <td>
                  <p :if={acl["rules"] == []}>Empty rules (not catch-all)</p>
                  <pre>{format_rules(acl["rules"])}</pre>
                </td>
                <td>{acl["revision"]}</td>
                <td>
                  <div class="management-actions">
                    <button class="btn btn-secondary btn-sm" phx-click="edit" phx-value-id={acl["id"]}>Edit</button>
                    <button class="btn btn-error btn-sm" phx-click="delete" phx-value-id={acl["id"]}>Delete</button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
      <.card :if={@service} title={if @editing, do: "Edit Desired ACL", else: "Create Desired ACL"}>
        <p :if={@editing} class="management-help">
          Editing {@editing["id"]}, revision {@editing["revision"]}. Renaming preserves its UUID.
        </p>
        <.form
          for={@form}
          id="dns-acl-form"
          phx-submit="save"
          phx-change="validate"
          phx-hook="ResetForm"
        >
          <label class="management-field"><span>Name</span><input
            class="input input-bordered"
            name="acl[name]"
            value={field_value(@form, :name)}
            maxlength="128"
            required
          /></label>
          <p :if={@field_errors[:name]} id="dns-acl-name-error" class="text-error">
            {@field_errors[:name]}
          </p>
          <label class="management-field"><span>Description</span><input
            class="input input-bordered"
            name="acl[description]"
            value={field_value(@form, :description)}
          /></label>
          <p :if={@field_errors[:description]} id="dns-acl-description-error" class="text-error">
            {@field_errors[:description]}
          </p>
          <label class="management-field"><span>Ordered Rules (one per line)</span><textarea
            id="dns-acl-rules"
            class="textarea textarea-bordered"
            name="acl[rules]"
            rows="8"
            maxlength={@max_rules_bytes}
          >{field_value(@form, :rules)}</textarea></label>
          <p :if={@field_errors[:rules]} id="dns-acl-rules-error" class="text-error">
            {@field_errors[:rules]}
          </p>
          <p class="management-help">
            Grammar: allow|deny any; allow|deny networks IP_OR_CIDR[, ...]; allow|deny countries ISO[, ...].
            Country codes are uppercase. Bare "allow networks" or "deny networks" means an empty network set.
            Blank text means zero rules. At most 128 rules and 128 networks total.
          </p>
          <div class="management-actions">
            <button class="btn btn-primary" type="submit" disabled={@field_errors != %{}}>{if @editing,
              do: "Save Desired ACL",
              else: "Create Desired ACL"}</button>
            <button id="dns-acl-cancel" class="btn btn-ghost" type="button" phx-click="cancel">Cancel / Reset</button>
          </div>
          <label class="management-field"><span>Built-in Preset</span><select
            id="dns-acl-preset"
            class="select select-bordered"
            name="preset"
          >
            <option value="">Select a preset</option>
            <option :for={preset <- @presets} value={preset} selected={@preset == preset}>
              {preset}
            </option>
          </select></label>
          <button
            id="dns-acl-apply-preset"
            class="btn btn-secondary"
            type="submit"
            name="operation"
            value="apply_preset"
            formnovalidate
          >Apply Preset to Empty Editor</button>
          <p class="management-help">
            Presets fill an empty editor only; they never replace populated rules. They do not enable enforcement.
          </p>
          <details id="dns-acl-country-picker" open>
            <summary>Append a Countries Rule</summary>
            <label class="management-field"><span>Search countries by name or code</span><input
              id="dns-acl-country-search"
              class="input input-bordered"
              name="country_search"
              value={@country_search}
              maxlength="256"
              phx-debounce="300"
            /></label>
            <button class="btn btn-ghost" type="button" phx-click="clear_country_search">Clear Country Search</button>
            <p>{length(@selected_countries)} countries selected; {length(@countries)} shown.</p>
            <div class="management-actions">
              <button
                :for={code <- @selected_countries}
                type="button"
                class="badge badge-secondary"
                data-selected-country-code={code}
                phx-click="toggle_country"
                phx-value-code={code}
              >{code} ×</button>
            </div>
            <div class="management-actions">
              <label :for={country <- @countries}>
                <input
                  id={"dns-acl-country-#{country.code}"}
                  class="checkbox"
                  type="checkbox"
                  data-country-code={country.code}
                  checked={country.code in @selected_countries}
                  phx-click="toggle_country"
                  phx-value-code={country.code}
                />
                {country.code} — {country.name}
              </label>
            </div>
            <label class="management-field"><span>Countries Rule Action</span><select
              id="dns-acl-country-action"
              class="select select-bordered"
              name="country_action"
            >
              <option value="allow" selected={@country_action == "allow"}>Allow</option>
              <option value="deny" selected={@country_action == "deny"}>Deny</option>
            </select></label>
            <button
              id="dns-acl-add-countries"
              class="btn btn-secondary"
              type="submit"
              name="operation"
              value="append_countries"
              formnovalidate
            >Append Selected Countries</button>
          </details>
        </.form>
      </.card>
      <.card :if={@service && @deleting} title="Confirm Desired ACL Deletion">
        <p>
          Delete {@deleting["name"]} at revision {@deleting["revision"]}? Only the desired ACL is removed; no Worker enforcement or export changes.
        </p>
        <div class="management-actions">
          <button
            id="dns-acl-confirm-delete"
            class="btn btn-error"
            phx-click="confirm_delete"
            phx-value-id={@deleting["id"]}
          >Confirm Delete</button>
          <button id="dns-acl-cancel-delete" class="btn btn-ghost" phx-click="cancel_delete">Cancel</button>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
