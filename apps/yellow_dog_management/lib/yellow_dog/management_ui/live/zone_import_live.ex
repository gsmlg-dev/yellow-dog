defmodule YellowDog.ManagementUI.ZoneImportLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.ConfigSpec
  alias YellowDog.Management.Domain
  alias YellowDog.ManagementUI.Hooks.CurrentPath

  @max_toml_bytes 1_048_576

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Import Zone",
       workers: Domain.list_workers(),
       server_id: nil,
       scope_error: nil,
       base_path: "/management/zones",
       source_form: to_form(%{"toml" => ""}, as: "import"),
       selection_form: to_form(%{"resource_id" => ""}, as: "import"),
       plan: nil,
       resources: [],
       selected_resource: nil,
       import_keys: %{},
       errors: [],
       imported_zone: nil
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    path_params = CurrentPath.route_path_params(socket, uri)
    server_id = path_params["server_id"]

    base_path =
      if server_id,
        do: "/server/#{URI.encode(server_id, &URI.char_unreserved?/1)}/dns/zones",
        else: "/management/zones"

    {:noreply,
     socket
     |> clear_preview()
     |> assign(
       server_id: server_id,
       scope_error: scope_error(server_id),
       base_path: base_path,
       workers: Domain.list_workers()
     )}
  end

  @impl true
  def handle_event("change_toml", %{"import" => params}, socket) when is_map(params) do
    {:noreply, update_source(socket, params["toml"])}
  end

  def handle_event("preview_import", %{"import" => params}, socket) when is_map(params) do
    toml = params["toml"]
    socket = update_source(socket, toml)

    with :ok <- bounded_toml(toml),
         {:ok, plan} <- ConfigSpec.decode(toml) do
      resources = plan["resources"]
      selected_resource = List.first(resources)
      selected_id = if selected_resource, do: selected_resource["id"], else: ""

      errors =
        if resources == [], do: ["WorkerPlan contains no DNS resources to import."], else: []

      {:noreply,
       assign(socket,
         plan: plan,
         resources: resources,
         selected_resource: selected_resource,
         selection_form: to_form(%{"resource_id" => selected_id}, as: "import"),
         import_keys: Map.new(resources, &{&1["id"], Ecto.UUID.generate()}),
         errors: errors
       )}
    else
      {:error, errors} -> {:noreply, assign(socket, :errors, error_messages(errors))}
    end
  end

  def handle_event("select_resource", %{"import" => params}, socket) when is_map(params) do
    case selected_resource(socket.assigns.resources, params["resource_id"]) do
      {:ok, resource} ->
        {:noreply,
         assign(socket,
           selected_resource: resource,
           selection_form: to_form(%{"resource_id" => resource["id"]}, as: "import"),
           errors: [],
           imported_zone: nil
         )}

      {:error, errors} ->
        {:noreply,
         assign(socket,
           selected_resource: nil,
           selection_form: to_form(%{"resource_id" => ""}, as: "import"),
           errors: errors,
           imported_zone: nil
         )}
    end
  end

  def handle_event("import_zone", %{"import" => params}, socket) when is_map(params) do
    worker_error = scope_error(socket.assigns.server_id)

    with nil <- worker_error,
         {:ok, resource} <- selected_resource(socket.assigns.resources, params["resource_id"]),
         {:ok, zone} <-
           Domain.mutate(
             "create_zone",
             %{"content" => resource["content"]},
             "operator",
             Map.fetch!(socket.assigns.import_keys, resource["id"])
           ) do
      {:noreply,
       socket
       |> assign(
         selected_resource: resource,
         selection_form: to_form(%{"resource_id" => resource["id"]}, as: "import"),
         imported_zone: zone,
         errors: [],
         scope_error: nil
       )
       |> put_flash(:info, "Zone draft imported. No version was confirmed or applied.")}
    else
      {:error, errors} ->
        {:noreply, assign(socket, :errors, error_messages(errors))}

      message when is_binary(message) ->
        {:noreply, assign(socket, scope_error: message, errors: [message], imported_zone: nil)}
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, assign(socket, :errors, ["Invalid import request. Validate a WorkerPlan first."])}
  end

  defp update_source(socket, toml) do
    {value, errors} =
      case bounded_toml(toml) do
        :ok -> {toml, []}
        {:error, errors} -> {"", errors}
      end

    socket
    |> clear_preview()
    |> assign(source_form: to_form(%{"toml" => value}, as: "import"), errors: errors)
  end

  defp clear_preview(socket) do
    assign(socket,
      plan: nil,
      resources: [],
      selected_resource: nil,
      selection_form: to_form(%{"resource_id" => ""}, as: "import"),
      import_keys: %{},
      errors: [],
      imported_zone: nil
    )
  end

  defp bounded_toml(toml) when is_binary(toml) and byte_size(toml) <= @max_toml_bytes,
    do: :ok

  defp bounded_toml(toml) when is_binary(toml),
    do: {:error, ["WorkerPlan TOML must be at most 1 MiB (1048576 bytes)."]}

  defp bounded_toml(_toml), do: {:error, ["WorkerPlan TOML must be text."]}

  defp selected_resource(resources, resource_id) when is_binary(resource_id) do
    case Enum.find(resources, &(&1["id"] == resource_id)) do
      nil -> {:error, ["Select a DNS resource from the validated WorkerPlan."]}
      resource -> {:ok, resource}
    end
  end

  defp selected_resource(_resources, _resource_id),
    do: {:error, ["Select a DNS resource from the validated WorkerPlan."]}

  defp scope_error(nil), do: nil

  defp scope_error(server_id) do
    case Domain.get_worker(server_id) do
      {:ok, _worker} -> nil
      {:error, error} -> error.message <> ". Zone import is disabled for this selection."
    end
  end

  defp error_messages(%{message: message}), do: [message]

  defp error_messages(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{path: path, message: message} ->
        location = if path == [], do: "WorkerPlan", else: Enum.map_join(path, ".", &to_string/1)
        location <> ": " <> message

      message when is_binary(message) ->
        message
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      servers={Enum.map(@workers, &%{id: &1["id"], name: &1["name"]})}
    >
      <h1>Import Zone</h1>
      <div class="management-actions">
        <.link navigate={@base_path} class="btn btn-ghost">Zones</.link>
        <.link navigate={@base_path <> "/new"} class="btn btn-primary">New Zone</.link>
      </div>
      <p class="management-help">
        Import one DNS Zone draft from a shared WorkerPlan TOML export. No Worker is required on
        the Management page. Import never confirms a version, assigns it, or applies a runtime change.
      </p>
      <div :if={@scope_error} id="zone-import-scope-error" class="alert alert-error" role="alert">
        {@scope_error}
      </div>
      <div :if={@errors != []} id="zone-import-errors" class="alert alert-error" role="alert">
        <ul>
          <li :for={message <- @errors}>{message}</li>
        </ul>
      </div>
      <.card title="Zone import">
        <p id="zone-import-format-help" class="management-help">
          Paste the complete WorkerPlan TOML downloaded from Management's Export TOML action
          (schema_version = 1), including services and resources. Maximum size: 1 MiB (1048576 bytes).
          The shared ConfigSpec validates every field and record; unsupported content is rejected,
          not discarded. SOA, NS and A records are supported by the current shared contract.
          BIND files and provider/snapshot source imports are not supported by this import page.
        </p>
        <.form
          for={@source_form}
          id="zone-import-form"
          phx-change="change_toml"
          phx-submit="preview_import"
        >
          <label for="zone-import-toml" class="management-field">
            <span>WorkerPlan TOML</span>
            <textarea
              id="zone-import-toml"
              class="textarea"
              name="import[toml]"
              rows="14"
              maxlength="1048576"
              required
              aria-describedby="zone-import-format-help"
            >{@source_form[:toml].value}</textarea>
          </label>
          <div class="management-actions">
            <button
              id="validate-zone-import"
              type="submit"
              class="btn btn-primary"
              disabled={not is_nil(@scope_error)}
              phx-disable-with="Validating…"
            >Validate WorkerPlan</button>
            <.link navigate={@base_path} class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
      </.card>
      <.card :if={@plan} title="Validated WorkerPlan">
        <p id="zone-import-plan">
          Worker {@plan["worker_id"]}, target revision {@plan["revision"]}, {length(@plan["services"])} services and {length(
            @resources
          )} DNS resources.
          Only the selected Zone content will be copied into a new Management draft.
        </p>
        <.form
          :if={@resources != []}
          for={@selection_form}
          id="zone-import-selection-form"
          phx-change="select_resource"
          phx-submit="import_zone"
        >
          <label class="management-field">
            <span>DNS resource</span>
            <select
              id="zone-import-resource"
              class="select"
              name="import[resource_id]"
              required
            >
              <option value="">Select a DNS resource</option>
              <option
                :for={resource <- @resources}
                value={resource["id"]}
                selected={resource["id"] == @selection_form[:resource_id].value}
              >
                {resource["content"]["name"]} — {resource["id"]} (version {resource["version"]})
              </option>
            </select>
          </label>
          <div :if={@selected_resource} id="zone-import-preview">
            <h2>{@selected_resource["content"]["name"]}</h2>
            <p>Source resource {@selected_resource["id"]}, version {@selected_resource["version"]}</p>
            <p>Digest <code>{@selected_resource["digest"]}</code></p>
            <div class="management-records">
              <table class="table table-striped">
                <thead>
                  <tr>
                    <th>Name</th><th>Type</th><th>TTL</th><th>Data</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={record <- @selected_resource["content"]["records"]}>
                    <td>{record["name"]}</td><td>{record["type"]}</td><td>{record["ttl"]}</td>
                    <td><code>{Jason.encode!(record["data"])}</code></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
          <div class="management-actions">
            <button
              id="import-zone-draft"
              type="submit"
              class="btn btn-warning"
              disabled={is_nil(@selected_resource) or not is_nil(@scope_error)}
              phx-disable-with="Importing…"
            >Import Zone</button>
          </div>
        </.form>
      </.card>
      <.card :if={@imported_zone} title="Imported Zone draft">
        <div id="zone-import-result">
          <p>{@imported_zone["name"]}, draft revision {@imported_zone["revision"]}</p>
          <p>No version was confirmed or applied. Review the draft before confirming it.</p>
          <.link
            navigate={"#{@base_path}/#{@imported_zone["id"]}/edit"}
            class="btn btn-primary"
          >Edit Zone Draft</.link>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
