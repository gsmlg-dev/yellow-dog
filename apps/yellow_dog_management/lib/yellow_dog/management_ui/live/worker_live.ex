defmodule YellowDog.ManagementUI.WorkerLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Domain, ExportScope, ProfileCatalog}
  alias YellowDog.ManagementUI.Hooks.CurrentPath
  alias YellowDog.ManagementUI.Submission

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(Submission.new(socket),
       page_title: "Server",
       worker: nil,
       preview: nil,
       target: nil,
       profiles: ProfileCatalog.list_server_profiles(),
       navigation_servers: []
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply,
     load(Submission.new(socket), CurrentPath.route_path_params(socket, uri)["server_id"])}
  end

  @impl true

  def handle_event(event, params, socket)
      when event in ~w(save_worker save_service assign unassign confirm_target) do
    if Submission.current?(
         socket,
         params["_submission"],
         submitted_editor(socket, event, params)
       ),
       do: handle_submission(event, params, socket),
       else: {:noreply, socket}
  end

  def handle_event(event, params, socket)
      when event in ~w(validate_worker validate_service validate_assignment) do
    {field, operation, form} =
      case event do
        "validate_worker" -> {"worker", "update_worker", :worker_form}
        "validate_service" -> {"service", "put_service", :service_form}
        "validate_assignment" -> {"assignment", "assign", :assignment_form}
      end

    values = params[field]

    if is_map(values) do
      socket =
        if values != socket.assigns[form].params,
          do: Submission.edit(socket, [operation]),
          else: socket

      {:noreply, assign(socket, form, to_form(values, as: field))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("edit_service", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.worker["services"], &(&1["id"] == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Service instance not found")}

      service ->
        params = %{
          "id" => service["instance_id"],
          "desired_state" => service["desired_state"],
          "listen_address" => service["config"]["listen_address"],
          "port" => to_string(service["config"]["port"])
        }

        {:noreply,
         assign(
           Submission.new(socket),
           :service_form,
           to_form(params, as: "service")
         )}
    end
  end

  def handle_event("preview", _params, socket) do
    case Domain.preview_target(socket.assigns.worker["id"]) do
      {:ok, preview} -> {:noreply, assign(socket, :preview, preview)}
      {:error, error} -> {:noreply, put_flash(socket, :error, message(error))}
    end
  end

  defp submitted_editor(socket, event, params)
       when event in ~w(save_worker save_service assign) do
    {field, operation, form} =
      case event do
        "save_worker" -> {"worker", "update_worker", :worker_form}
        "save_service" -> {"service", "put_service", :service_form}
        "assign" -> {"assignment", "assign", :assignment_form}
      end

    if params[field] == socket.assigns[form].params, do: operation
  end

  defp submitted_editor(_socket, _event, _params), do: nil

  defp handle_submission("save_worker", %{"worker" => params} = payload, socket) do
    socket = assign(socket, :worker_form, to_form(params, as: "worker"))

    command(
      socket,
      "update_worker",
      Map.merge(Map.take(params, ~w(name profile_name)), %{
        "id" => socket.assigns.worker["id"],
        "expected_revision" => socket.assigns.worker["revision"]
      }),
      payload["_submission"]
    )
  end

  defp handle_submission("save_service", %{"service" => params} = payload, socket) do
    socket = assign(socket, :service_form, to_form(params, as: "service"))

    case Integer.parse(params["port"] || "") do
      {port, ""} ->
        command(
          socket,
          "put_service",
          %{
            "worker_id" => socket.assigns.worker["id"],
            "expected_revision" => socket.assigns.worker["revision"],
            "id" => params["id"],
            "type" => "dns",
            "desired_state" => params["desired_state"],
            "config" => %{"listen_address" => params["listen_address"], "port" => port}
          },
          payload["_submission"]
        )

      _ ->
        {:noreply, socket |> clear_flash(:info) |> put_flash(:error, "Port must be an integer")}
    end
  end

  defp handle_submission("assign", %{"assignment" => params} = payload, socket) do
    socket = assign(socket, :assignment_form, to_form(params, as: "assignment"))

    command(
      socket,
      "assign",
      Map.take(params, ~w(service_id resource_version_id)),
      payload["_submission"]
    )
  end

  defp handle_submission(
         "unassign",
         %{"service_id" => service_id, "zone_id" => zone_id} = payload,
         socket
       ) do
    command(
      socket,
      "unassign",
      %{"service_id" => service_id, "zone_id" => zone_id},
      payload["_submission"]
    )
  end

  defp handle_submission("confirm_target", params, socket),
    do: command(socket, "confirm_target", %{}, params["_submission"])

  defp handle_submission(_event, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid submission")}

  defp command(socket, operation, params, token) do
    worker = socket.assigns.worker

    params =
      Map.merge(%{"worker_id" => worker["id"], "expected_revision" => worker["revision"]}, params)

    {socket, key} = Submission.prepare(socket, operation, params, token)

    case Domain.mutate(operation, params, "operator", key) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> Submission.new()
         |> load(worker["id"])
         |> put_flash(:info, success_message(operation))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, message(error))}
    end
  end

  defp success_message("assign"), do: "Assignment saved. Worker actual state remains unknown."
  defp success_message("unassign"), do: "Assignment removed. Worker actual state remains unknown."

  defp success_message("confirm_target"),
    do: "Target prepared. Worker actual state remains unknown."

  defp success_message(_operation),
    do: "Configuration saved. Worker actual state remains unknown."

  defp load(socket, worker_id) do
    case Domain.get_worker(worker_id) do
      {:ok, worker} ->
        target =
          case Domain.get_target(worker_id) do
            {:ok, value} -> value
            {:error, _error} -> nil
          end

        versions =
          for zone <- Domain.list_zones(),
              version <- Domain.list_versions(zone["id"]),
              do: {"#{zone["name"]} v#{version["version"]}", version["id"]}

        assign(socket,
          worker: worker,
          page_title: worker["name"],
          target: target,
          preview: nil,
          versions: versions,
          navigation_servers: Enum.map(Domain.list_workers(), &%{id: &1["id"], name: &1["name"]}),
          worker_form: to_form(Map.take(worker, ~w(name profile_name)), as: "worker"),
          service_form:
            to_form(
              %{
                "id" => "dns",
                "listen_address" => "127.0.0.1",
                "port" => "5300",
                "desired_state" => "stopped"
              },
              as: "service"
            ),
          assignment_form: to_form(%{}, as: "assignment")
        )

      {:error, error} ->
        socket |> put_flash(:error, message(error)) |> push_navigate(to: "/server")
    end
  end

  defp message(error), do: error[:message] || error["message"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} servers={@navigation_servers}>
      <input id="submission-intent" type="hidden" value={@submission_id} />
      <div :if={@worker} class="max-w-7xl space-y-6" id="server-dashboard">
        <div>
          <h1 class="text-3xl font-bold">{@worker["name"]}</h1><p class="text-on-surface-variant">
            Actual runtime state is unknown. Desired configuration does not report service health.
          </p>
        </div>
        <.card title="Server configuration">
          <.form
            for={@worker_form}
            id="worker-edit-form"
            phx-submit="save_worker"
            phx-change="validate_worker"
            class="flex flex-wrap gap-4"
          >
            <input type="hidden" name="_submission" value={@submission_id} />
            <input
              class="input input-bordered"
              name="worker[name]"
              value={@worker_form[:name].value}
              required
              aria-label="Name"
            />
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
          <p class="text-sm text-on-surface-variant">
            Profiles are descriptive catalog metadata, not service enablement. Changing a profile
            does not alter expected capabilities, services, assignments or prepared targets,
            and does not start agents.
          </p>
          <.link navigate={"/server/#{@worker["id"]}/dns/zones"} class="btn btn-outline mt-4">DNS Zones</.link>
        </.card>
        <.card title="DNS service instances">
          <div class="overflow-x-auto">
            <table class="table" id="dns-services">
              <thead>
                <tr>
                  <th>Instance</th><th>Desired state</th><th>Runtime</th><th>Listen</th><th>Edit</th>
                </tr>
              </thead><tbody>
                <tr :for={service <- @worker["services"]}>
                  <td>{service["instance_id"]}</td><td>{service["desired_state"]}</td><td>
                    {service["actual_state"]}
                  </td><td>{service["config"]["listen_address"]}:{service["config"]["port"]}</td><td>
                    <button
                      class="btn btn-ghost btn-sm"
                      type="button"
                      phx-click="edit_service"
                      phx-value-id={service["id"]}
                    >Edit</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <.form
            for={@service_form}
            id="service-form"
            phx-submit="save_service"
            phx-change="validate_service"
            class="grid gap-4 mt-4 md:grid-cols-2"
          >
            <input type="hidden" name="_submission" value={@submission_id} />
            <label class="form-control"><span class="label">Instance ID</span><input
              class="input input-bordered"
              name="service[id]"
              value={@service_form[:id].value}
              required
            /></label>
            <label class="form-control"><span class="label">Listen address</span><input
              class="input input-bordered"
              name="service[listen_address]"
              value={@service_form[:listen_address].value}
              required
            /></label>
            <label class="form-control"><span class="label">Port</span><input
              class="input input-bordered"
              type="number"
              name="service[port]"
              value={@service_form[:port].value}
              min="1"
              max="65535"
              required
            /></label>
            <label class="form-control"><span class="label">Desired state</span><select
              class="select select-bordered"
              name="service[desired_state]"
            ><option value="stopped" selected={@service_form[:desired_state].value == "stopped"}>
              Stopped
            </option><option
              value="running"
              selected={@service_form[:desired_state].value == "running"}
            >
              Running
            </option></select></label>
            <button class="btn btn-primary" type="submit" phx-disable-with="Saving…">Save desired service</button>
          </.form>
        </.card>
        <.card title="Resource assignments">
          <div class="overflow-x-auto">
            <table class="table" id="resource-assignments">
              <thead>
                <tr>
                  <th>Zone</th><th>Version</th><th>Remove</th>
                </tr>
              </thead><tbody>
                <tr :for={assignment <- @worker["assignments"]}>
                  <td>{assignment["zone_id"]}</td><td>{assignment["version"]}</td><td>
                    <button
                      type="button"
                      class="btn btn-outline btn-sm"
                      phx-click="unassign"
                      phx-value-_submission={@submission_id}
                      phx-value-service_id={assignment["service_id"]}
                      phx-value-zone_id={assignment["zone_id"]}
                      phx-disable-with="Removing…"
                    >Unassign</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <.form
            :if={@worker["services"] != [] and @versions != []}
            for={@assignment_form}
            id="assignment-form"
            phx-submit="assign"
            phx-change="validate_assignment"
            class="flex flex-wrap gap-4 mt-4"
          >
            <input type="hidden" name="_submission" value={@submission_id} />
            <select class="select select-bordered" name="assignment[service_id]" aria-label="Service"><option
              :for={service <- @worker["services"]}
              value={service["id"]}
              selected={@assignment_form[:service_id].value == service["id"]}
            >
              {service["instance_id"]}
            </option></select>
            <select
              class="select select-bordered"
              name="assignment[resource_version_id]"
              aria-label="Zone version"
            ><option
              :for={{label, version_id} <- @versions}
              value={version_id}
              selected={@assignment_form[:resource_version_id].value == version_id}
            >
              {label}
            </option></select>
            <button class="btn btn-primary" type="submit" phx-disable-with="Saving…">Assign version</button>
          </.form>
        </.card>
        <.card title="Target preview and export">
          <p id="target-export-scope" class="management-help">{ExportScope.description()}</p>
          <div class="flex flex-wrap gap-4">
            <button class="btn btn-outline" type="button" phx-click="preview">Preview target</button><button
              class="btn btn-primary"
              type="button"
              phx-click="confirm_target"
              phx-value-_submission={@submission_id}
              phx-disable-with="Preparing…"
            >Confirm prepared target</button>
            <.link
              :if={@target}
              href={"/api/workers/#{@worker["id"]}/targets/#{@target["revision"]}/export"}
              class="btn btn-secondary"
            >Export TOML revision {@target["revision"]}</.link>
          </div>
          <pre :if={@preview} id="target-preview" class="mt-4 overflow-auto">{Jason.encode!(@preview, pretty: true)}</pre>
          <p :if={@target} class="mt-4">
            Status: {@target["status"]}; runtime: {@target["actual_state"]}
          </p>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
