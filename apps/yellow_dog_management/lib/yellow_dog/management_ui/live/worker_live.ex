defmodule YellowDog.ManagementUI.WorkerLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Database, Domain, ExportScope, ProfileCatalog, WorkerConnections}
  alias YellowDog.ManagementUI.Hooks.CurrentPath
  alias YellowDog.ManagementUI.{ServicePaths, Submission, WorkerConnection}

  @observation_fields ~w(connection_status last_seen_at reported_capabilities reported_services applied_revision applied_digest apply_error actual_state)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(Submission.new(socket),
       refresh_timer:
         if(connected?(socket), do: Process.send_after(self(), :refresh_connection, 5000)),
       page_title: "Worker",
       worker: nil,
       service: nil,
       references: nil,
       preview: nil,
       target: nil,
       history: [],
       dirty: false,
       observation_error: nil,
       error: nil,
       field_errors: [],
       scope: %{},
       loaded_scope: nil,
       profiles: ProfileCatalog.list_server_profiles(),
       bootstrap: nil,
       management_url: nil,
       navigation_servers: []
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    scope = CurrentPath.route_path_params(socket, uri)

    {:noreply,
     socket
     |> assign(scope: scope, management_url: WorkerConnection.origin(uri), bootstrap: nil)
     |> load()}
  end

  @impl true
  def handle_info(:refresh_connection, socket) do
    if socket.assigns.refresh_timer, do: Process.cancel_timer(socket.assigns.refresh_timer)
    socket = assign(socket, :refresh_timer, Process.send_after(self(), :refresh_connection, 5000))

    case Database.read(fn ->
           with %{"id" => id} <- socket.assigns.worker,
                {:ok, worker} <- Domain.get_worker(id),
                do: {:ok, worker}
         end) do
      {:ok, {:ok, worker}} ->
        # Polling changes observations only; editor revisions, input and preview stay fixed.
        {:noreply,
         assign(socket,
           worker: Map.merge(socket.assigns.worker, Map.take(worker, @observation_fields)),
           observation_error: nil
         )}

      {:error, error} ->
        {:noreply, assign(socket, :observation_error, message(error))}

      {:ok, _} ->
        {:noreply,
         assign(
           socket,
           :observation_error,
           "Worker observations could not be refreshed. Showing last known state."
         )}
    end
  end

  @impl true
  def handle_event("rotate_token", %{"_submission" => intent}, socket) do
    if socket.assigns.worker != nil and socket.assigns.live_action == :connection and
         Submission.current?(socket, intent) do
      # Retire this interaction even on an ambiguous failure; recovery requires an explicit reset.
      socket = socket |> Submission.new() |> assign(:bootstrap, nil)

      case WorkerConnections.rotate(socket.assigns.worker["id"]) do
        {:ok, %{"worker" => worker, "token" => token}} ->
          {:noreply,
           assign(socket,
             bootstrap:
               WorkerConnections.bootstrap(worker, token, socket.assigns.management_url)
               |> WorkerConnection.protect()
           )
           |> put_flash(:info, "Token reset. Update this Worker's connection configuration.")}

        {:error, error} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             message(error) <>
               ". If the outcome is uncertain, reload connection observations and explicitly reset again; issued tokens cannot be recovered."
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("rotate_token", _params, socket), do: {:noreply, socket}

  def handle_event("retire_connection", %{"id" => id}, socket) do
    if socket.assigns.bootstrap && socket.assigns.bootstrap.id == id,
      do: {:noreply, assign(socket, :bootstrap, nil)},
      else: {:noreply, socket}
  end

  def handle_event("dismiss_connection", _params, socket),
    do: {:noreply, assign(socket, :bootstrap, nil)}

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, "Connection configuration copied.")}

  def handle_event("copy_failed", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Select and copy the configuration text manually.")}

  def handle_event("reload", _params, socket), do: {:noreply, load(socket)}

  def handle_event(event, params, socket)
      when event in ~w(save_worker save_service confirm_target) do
    if allowed_event?(socket, event) and
         Submission.current?(
           socket,
           params["_submission"],
           submitted_editor(socket, event, params)
         ),
       do: handle_submission(event, params, socket),
       else: {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ~w(validate_worker validate_service) do
    {field, operations, form} =
      case event do
        "validate_worker" -> {"worker", ["update_worker"], :worker_form}
        "validate_service" -> {"service", ["create_service", "update_service"], :service_form}
      end

    values = params[field]

    if is_map(values) and allowed_event?(socket, String.replace(event, "validate", "save")) do
      socket =
        if values != socket.assigns[form].params,
          do: Submission.edit(socket, operations),
          else: socket

      {:noreply, assign(socket, [{form, to_form(values, as: field)}, {:dirty, true}])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("preview", _params, socket) do
    if socket.assigns.worker != nil and socket.assigns.live_action in [:targets, :target] do
      case Database.read(fn -> Domain.preview_target(socket.assigns.worker["id"]) end) do
        {:ok, {:ok, preview}} ->
          {:noreply,
           socket
           |> Submission.new()
           |> assign(preview: preview, observation_error: nil, error: nil, field_errors: [])}

        {:ok, {:error, error}} ->
          failure(socket, error)

        {:error, error} ->
          {:noreply, assign(socket, :observation_error, message(error))}
      end
    else
      {:noreply, socket}
    end
  end

  defp allowed_event?(socket, "save_worker"),
    do: socket.assigns.worker != nil and socket.assigns.live_action == :show

  defp allowed_event?(socket, "save_service"),
    do:
      socket.assigns.worker != nil and socket.assigns.live_action in [:new_service, :edit_service]

  defp allowed_event?(socket, "confirm_target"),
    do:
      socket.assigns.worker != nil and socket.assigns.live_action in [:targets, :target] and
        socket.assigns.preview != nil

  defp submitted_editor(socket, "save_worker", params) do
    if params["worker"] == socket.assigns.worker_form.params, do: "update_worker"
  end

  defp submitted_editor(socket, "save_service", params) do
    if params["service"] == socket.assigns.service_form.params, do: service_operation(socket)
  end

  defp submitted_editor(_socket, _event, _params), do: nil

  defp handle_submission("save_worker", %{"worker" => params} = payload, socket)
       when is_map(params) do
    socket = assign(socket, worker_form: to_form(params, as: "worker"), dirty: true)

    command(
      socket,
      "update_worker",
      Map.merge(Map.take(params, ~w(name profile_name)), %{"id" => socket.assigns.worker["id"]}),
      payload["_submission"]
    )
  end

  defp handle_submission("save_service", %{"service" => params} = payload, socket)
       when is_map(params) do
    socket = assign(socket, service_form: to_form(params, as: "service"), dirty: true)

    case Integer.parse(params["port"] || "") do
      {port, ""} ->
        command_params = %{
          "instance_id" => params["id"],
          "type" => "dns",
          "desired_state" => params["desired_state"],
          "config" => %{"listen_address" => params["listen_address"], "port" => port}
        }

        command_params =
          if socket.assigns.service,
            do: Map.put(command_params, "service_id", socket.assigns.service["id"]),
            else: command_params

        command(socket, service_operation(socket), command_params, payload["_submission"])

      _ ->
        failure(socket, %{code: "invalid_config", message: "Port must be an integer"})
    end
  end

  defp handle_submission("confirm_target", params, socket) do
    command(
      socket,
      "confirm_target",
      %{"expected_revision" => socket.assigns.preview["worker_revision"]},
      params["_submission"]
    )
  end

  defp handle_submission(_event, _params, socket), do: {:noreply, socket}

  defp service_operation(socket),
    do: if(socket.assigns.service, do: "update_service", else: "create_service")

  defp command(socket, operation, params, token) do
    params =
      Map.merge(
        %{
          "worker_id" => socket.assigns.worker["id"],
          "expected_revision" => socket.assigns.worker["revision"]
        },
        params
      )

    {socket, key} = Submission.prepare(socket, operation, params, token)

    case Domain.mutate(operation, params, "operator", key) do
      {:ok, _result} ->
        text =
          if operation == "confirm_target",
            do: "Target prepared and published. Worker application is not yet confirmed.",
            else: "Configuration saved. Service changes require preview and explicit publication."

        {:noreply, socket |> load() |> put_flash(:info, text)}

      {:error, error} ->
        failure(socket, error)
    end
  end

  defp failure(socket, error) do
    details = error[:details] || error["details"] || %{}

    {:noreply,
     socket
     |> clear_flash(:info)
     |> assign(error: message(error), field_errors: details["errors"] || [])
     |> put_flash(:error, message(error))}
  end

  defp load(socket) do
    case Database.read(fn -> load_available(socket) end) do
      {:ok, loaded} ->
        assign(loaded, :loaded_scope, {socket.assigns.live_action, socket.assigns.scope})

      {:error, error} ->
        socket =
          if socket.assigns.loaded_scope == {socket.assigns.live_action, socket.assigns.scope} do
            socket
          else
            # A failed destination load cannot carry another route's editor or intent.
            socket
            |> Submission.new()
            |> assign(
              worker: nil,
              service: nil,
              references: nil,
              preview: nil,
              target: nil,
              history: [],
              worker_form: nil,
              service_form: nil,
              dirty: false,
              bootstrap: nil,
              loaded_scope: nil,
              error: nil,
              field_errors: []
            )
          end

        assign(socket, :observation_error, message(error))
    end
  end

  defp load_available(socket) do
    case Domain.get_worker(socket.assigns.scope["server_id"]) do
      {:ok, worker} ->
        socket =
          socket
          |> Submission.new()
          |> assign(
            worker: worker,
            observation_error: nil,
            page_title: worker["name"],
            preview: nil,
            target: target(worker["id"], socket.assigns.scope["revision"]),
            history: Domain.list_worker_target_history(worker["id"], 20),
            service: nil,
            references: nil,
            dirty: false,
            error: nil,
            field_errors: [],
            navigation_servers:
              Enum.map(Domain.list_workers(), &%{id: &1["id"], name: &1["name"]}),
            worker_form: to_form(Map.take(worker, ~w(name profile_name)), as: "worker"),
            service_form:
              to_form(
                %{
                  "id" => "",
                  "listen_address" => "127.0.0.1",
                  "port" => "5300",
                  "desired_state" => "stopped"
                },
                as: "service"
              )
          )

        if socket.assigns.live_action == :edit_service do
          case Domain.get_service(worker["id"], socket.assigns.scope["service_id"]) do
            {:ok, service} ->
              {:ok, references} = Domain.list_service_references(worker["id"], service["id"])

              assign(socket,
                service: service,
                references: references,
                service_form:
                  to_form(
                    %{
                      "id" => service["instance_id"],
                      "listen_address" => service["config"]["listen_address"],
                      "port" => to_string(service["config"]["port"]),
                      "desired_state" => service["desired_state"]
                    },
                    as: "service"
                  )
              )

            {:error, error} ->
              socket
              |> put_flash(:error, message(error))
              |> push_patch(to: ServicePaths.server_path(worker["id"], :services))
          end
        else
          socket
        end

      {:error, error} ->
        socket |> put_flash(:error, message(error)) |> push_navigate(to: "/server")
    end
  end

  defp target(worker_id, nil) do
    case Domain.get_target(worker_id) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp target(worker_id, revision) do
    with {value, ""} <- Integer.parse(revision),
         {:ok, target} <- Domain.get_target(worker_id, value),
         do: target,
         else: (_ -> nil)
  end

  defp message(error),
    do: "#{error[:code] || error["code"]}: #{error[:message] || error["message"]}"

  defp tab(action) when action in [:services, :dns, :new_service, :edit_service], do: :services
  defp tab(action) when action in [:targets, :target], do: :targets
  defp tab(action), do: action

  defp reference_count(worker, service),
    do: Enum.count(worker["assignments"], &(&1["service_id"] == service["id"]))

  defp report(worker, service) do
    case get_in(worker, ["reported_services", service["instance_id"], "state"]) do
      nil ->
        "Unknown; no report"

      value ->
        value <>
          if(worker["connection_status"] == "connected",
            do: " (last report)",
            else: " (last known; Worker offline)"
          )
    end
  end

  defp errors_for_field(errors, field) do
    Enum.filter(errors, fn error -> field in (error["path"] || error[:path] || []) end)
  end

  defp error_text(error),
    do: "#{error["code"] || error[:code]}: #{error["message"] || error[:message]}"

  defp service_change(preview, id) do
    previous = get_in(preview, ["previous_plan", "services"]) || []
    current = preview["plan"]["services"]
    before = Enum.find(previous, &(&1["id"] == id))
    after_service = Enum.find(current, &(&1["id"] == id))
    "#{id}: #{service_summary(before)} → #{service_summary(after_service)}"
  end

  defp service_summary(nil), do: "absent"

  defp service_summary(service),
    do:
      "#{service["desired_state"]}, #{service["config"]["listen_address"]}:#{service["config"]["port"]}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} servers={@navigation_servers}>
      <p :if={@observation_error} id="node-observation-error" role="status">{@observation_error}</p>
      <button
        :if={@observation_error && is_nil(@worker)}
        id="retry-node-load"
        type="button"
        class="btn btn-outline"
        phx-click="reload"
      >Retry loading this page</button>
      <input id="submission-intent" type="hidden" value={@submission_id} />
      <div
        :if={@worker}
        id="node-workflow"
        phx-hook="NodeWorkflow"
        data-dirty={to_string(@dirty)}
        data-reset-key={@submission_id}
        class="max-w-7xl space-y-6"
      >
        <header id="server-dashboard">
          <h1 class="text-3xl font-bold">{@worker["name"]}</h1>
          <p>Worker {@worker["id"]} · Saved configuration revision {@worker["revision"]}</p>
          <p id="worker-connection-status" class="management-help">
            Connection: {WorkerConnection.status(@worker)} · Last contact: {@worker["last_seen_at"] ||
              "Never"}. Actual runtime state is unknown until reported by the Worker.
          </p>
          <p id="worker-applied-revision">
            Last reported applied revision: {@worker["applied_revision"] || "None"}
          </p>
        </header>
        <nav aria-label="Worker tabs" class="flex flex-wrap gap-4" id="worker-tabs">
          <.link
            :for={
              {action, destination, label} <- [
                {:show, :dashboard, "Basic information"},
                {:connection, :connection, "Authentication & connection"},
                {:services, :services, "Services"},
                {:targets, :targets, "Configuration target"}
              ]
            }
            patch={ServicePaths.server_path(@worker["id"], destination)}
            aria-current={if tab(@live_action) == action, do: "page"}
            class={if tab(@live_action) == action, do: "btn btn-primary", else: "btn btn-outline"}
          >{label}</.link>
        </nav>
        <div :if={@error} id="node-command-error" role="alert">
          <p class="text-error">{@error}</p>
          <p :for={error <- @field_errors} class="text-error">{Jason.encode!(error)}</p>
          <button
            type="button"
            class="btn btn-outline"
            phx-click="reload"
            data-confirm="Discard unsaved input and reload the current saved configuration?"
          >Discard input and reload</button>
        </div>
        <.card :if={@live_action == :show} title="Basic information">
          <.form
            for={@worker_form}
            id="worker-edit-form"
            phx-submit="save_worker"
            phx-change="validate_worker"
            class="flex flex-wrap gap-4"
          >
            <input type="hidden" name="_submission" value={@submission_id} />
            <label class="form-control"><span class="label">Name</span><input
              class="input input-bordered"
              name="worker[name]"
              value={@worker_form[:name].value}
              required
            /></label>
            <label class="form-control"><span class="label">Profile</span><select
              id="worker-edit-profile"
              class="select select-bordered"
              name="worker[profile_name]"
            >
              <option
                :for={profile <- @profiles}
                value={profile.name}
                selected={to_string(profile.name) == @worker_form[:profile_name].value}
              >
                {profile.name} — {profile.description}
              </option>
            </select></label>
            <button class="btn btn-primary" type="submit" phx-disable-with="Saving…">Save name and profile</button>
          </.form>
          <p class="management-help">
            Profiles are descriptive catalog metadata, not service enablement. Changing a profile does not alter services, data assignments or prepared targets.
          </p>
        </.card>
        <.card :if={@live_action == :connection} title="Authentication & connection">
          <p>Management endpoint: {@management_url}</p>
          <p>Last contact: {@worker["last_seen_at"] || "Never"}</p>
          <p>Reported capabilities: {Enum.join(@worker["reported_capabilities"] || [], ", ")}</p>
          <p>Reported service states: {WorkerConnection.services(@worker)}</p>
          <p>Last reported digest: {@worker["applied_digest"] || "None"}</p>
          <p :if={@worker["apply_error"]} class="text-error">
            Last reported error: {@worker["apply_error"]}
          </p>
          <p class="management-help">
            Use the bootstrap.toml issued at registration. It contains the Management URL, Worker ID, private token and polling interval. Stored credentials cannot be displayed again. Resetting immediately invalidates the previous credential and requires reconfiguring the Worker.
          </p>
          <button
            class="btn btn-outline"
            type="button"
            phx-click="rotate_token"
            phx-value-_submission={@submission_id}
            phx-disable-with="Resetting…"
            data-confirm="Reset this Worker's token? The previous credential immediately stops working; reconfigure the Worker with the new bootstrap."
          >Reset token</button>
        </.card>
        <WorkerConnection.configuration
          :if={@live_action == :connection and @bootstrap}
          bootstrap={@bootstrap}
        />
        <.card :if={tab(@live_action) == :services} title="Service instances">
          <p class="management-help">
            DNS is supported. DHCPv4, DHCPv6, mDNS, Netboot and Identity configuration are unavailable. Saving desired state does not publish a target or start a Management service.
          </p>
          <.link patch={ServicePaths.server_path(@worker["id"], :service_new)} class="btn btn-primary">Create DNS service</.link>
          <div class="management-records">
            <table class="table" id="dns-services">
              <thead>
                <tr>
                  <th>Instance / type</th><th>Desired state</th><th>Listener</th><th>References</th><th>
                    Observed state
                  </th><th>Action</th>
                </tr>
              </thead><tbody>
                <tr :for={service <- @worker["services"]}>
                  <td>{service["instance_id"]} / {service["type"]}</td><td>
                    {service["desired_state"]}
                  </td><td>{service["config"]["listen_address"]}:{service["config"]["port"]}</td>
                  <td>{reference_count(@worker, service)} pinned Zones</td><td>
                    {report(@worker, service)}
                  </td>
                  <td>
                    <.link
                      patch={ServicePaths.server_path(@worker["id"], {:service_edit, service["id"]})}
                      class="btn btn-outline"
                    >Edit</.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@worker["services"] == []}>
            No service instances. Create one to save desired configuration.
          </p>
        </.card>
        <.card
          :if={@live_action in [:new_service, :edit_service]}
          title={if @service, do: "Edit DNS service", else: "Create DNS service"}
        >
          <.form
            for={@service_form}
            id="service-form"
            phx-submit="save_service"
            phx-change="validate_service"
            class="grid gap-4"
          >
            <input type="hidden" name="_submission" value={@submission_id} />
            <label class="form-control"><span class="label">Instance ID</span><input
              class="input input-bordered"
              name="service[id]"
              value={@service_form[:id].value}
              readonly={@service != nil}
              required
            /></label>
            <p>Service type: DNS</p>
            <label class="form-control"><span class="label">Listen IPv4 address</span><input
              class="input input-bordered"
              name="service[listen_address]"
              value={@service_form[:listen_address].value}
              required
            /></label>
            <p :for={error <- errors_for_field(@field_errors, "listen_address")} class="text-error">
              {error_text(error)}
            </p>
            <label class="form-control"><span class="label">Port</span><input
              class="input input-bordered"
              type="number"
              name="service[port]"
              value={@service_form[:port].value}
              min="1"
              max="65535"
              required
            /></label>
            <p :for={error <- errors_for_field(@field_errors, "port")} class="text-error">
              {error_text(error)}
            </p>
            <label class="form-control"><span class="label">Desired state</span><select
              class="select select-bordered"
              name="service[desired_state]"
            >
              <option value="stopped" selected={@service_form[:desired_state].value == "stopped"}>
                Stopped
              </option><option
                value="running"
                selected={@service_form[:desired_state].value == "running"}
              >
                Running
              </option>
            </select></label>
            <button class="btn btn-primary" type="submit" phx-disable-with="Saving…">Save desired service</button>
          </.form>
          <section :if={@references} id="service-references">
            <h2>Data references for {@service["instance_id"]}</h2>
            <p class="management-help">
              Pinned Zones are included in targets. Saved Views and ACLs remain Management relationships and are not serialized into the current WorkerPlan.
            </p>
            <p :for={zone <- @references["zones"]}>
              {zone["name"]} ({zone["zone_id"]}) · version {zone["version"]} · {zone[
                "resource_version_id"
              ]}
            </p>
            <p :for={view <- @references["views"]}>Saved View: {view["name"]}</p>
            <p :for={acl <- @references["acls"]}>Saved ACL: {acl["name"]}</p>
            <p>Showing up to {@references["limit"]} entries per reference type.</p>
            <.link
              navigate={ServicePaths.server_path(@worker["id"], :dns_zones)}
              class="btn btn-outline"
            >Edit Zone data and assignments</.link>
            <.link
              navigate={ServicePaths.server_path(@worker["id"], {:dns_views_service, @service["id"]})}
              class="btn btn-outline"
            >Edit DNS Views</.link>
            <.link
              navigate={ServicePaths.server_path(@worker["id"], {:dns_acl_service, @service["id"]})}
              class="btn btn-outline"
            >Edit DNS ACLs</.link>
          </section>
        </.card>
        <.card :if={tab(@live_action) == :targets} title="Configuration target">
          <p id="target-export-scope" class="management-help">{ExportScope.description()}</p>
          <p>
            Saved desired configuration revision: {@worker["revision"]}. Last reported applied revision: {@worker[
              "applied_revision"
            ] || "None"}; digest: {@worker["applied_digest"] || "None"}.
          </p>
          <p class="management-help">
            Reports are last-known authenticated observations. Publication does not confirm Worker application.
          </p>
          <button class="btn btn-outline" type="button" phx-click="preview">Preview target</button>
          <section :if={@preview} id="target-preview">
            <h2>Review target revision {@preview["next_target_revision"]}</h2>
            <p>Bound saved configuration revision: {@preview["worker_revision"]}</p>
            <h3>Included services</h3>
            <p :for={service <- @preview["plan"]["services"]}>
              {service["id"]}: {service["desired_state"]}, {service["config"]["listen_address"]}:{service[
                "config"
              ]["port"]}; pinned resources: {Enum.join(service["resources"], ", ")}
            </p>
            <h3>Pinned resource versions</h3>
            <p :for={resource <- @preview["plan"]["resources"]}>
              {resource["id"]} · version {resource["version"]}
            </p>
            <div :for={group <- ["services", "resources"]}>
              <h3>{String.capitalize(group)} changes</h3>
              <p :for={kind <- ["added", "replaced", "removed"]}>
                {String.capitalize(kind)}: {Enum.join(@preview["diff"][group][kind], ", ")} ({length(
                  @preview["diff"][group][kind]
                )})
              </p>
            </div>
            <p :for={
              id <-
                @preview["diff"]["services"]["added"] ++
                  @preview["diff"]["services"]["replaced"] ++ @preview["diff"]["services"]["removed"]
            }>
              {service_change(@preview, id)}
            </p>
            <p :for={change <- @preview["diff"]["services"]["lifecycle"]}>
              {change["id"]}: desired state {change["from"]} → {change["to"]}
            </p>
            <details>
              <summary>Exact preview and grouped diff JSON</summary><pre class="overflow-auto">{Jason.encode!(@preview, pretty: true)}</pre>
            </details>
            <button
              class="btn btn-primary"
              type="button"
              phx-click="confirm_target"
              phx-value-_submission={@submission_id}
              phx-disable-with="Publishing…"
              data-confirm="Publish this reviewed target? Connected Workers may immediately apply listener, stop and removal changes."
            >Publish configuration</button>
          </section>
          <section :if={@target} id="selected-target">
            <h2>Immutable published target revision {@target["revision"]}</h2><p>
              Digest: {@target["digest"]}
            </p>
            <.link
              href={"/api/workers/#{@worker["id"]}/targets/#{@target["revision"]}/export"}
              class="btn btn-secondary"
            >Export TOML revision {@target["revision"]}</.link>
            <details>
              <summary>Immutable target snapshot</summary><pre class="overflow-auto">{Jason.encode!(@target["plan"], pretty: true)}</pre>
            </details>
          </section>
          <p :if={@live_action == :target and is_nil(@target)} role="alert">
            Target revision not found for this Worker.
          </p>
          <h2>Published history (latest 20)</h2>
          <ul id="worker-target-history">
            <li :for={target <- @history}>
              <.link patch={ServicePaths.server_path(@worker["id"], {:target, target["revision"]})}>Revision {target[
                "revision"
              ]} · {target["digest"]}</.link>
            </li>
          </ul>
          <.link navigate="/management/config" class="btn btn-outline">Cross-node configuration history</.link>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
