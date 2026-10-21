defmodule YellowDog.ManagementUI.WorkersLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Domain, WorkerConnections}
  alias YellowDog.ManagementUI.WorkerConnection

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_workers, 5000)

    {:ok,
     assign(socket,
       page_title: "Workers",
       workers: Domain.list_workers(),
       bootstrap: nil,
       registered_worker: nil,
       management_url: nil,
       submission_id: Ecto.UUID.generate(),
       enrollment_intent: Ecto.UUID.generate(),
       enrollment_dirty: false,
       enrollment: Domain.worker_enrollment_settings(),
       form: to_form(%{"name" => ""}, as: "worker")
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    socket =
      socket
      |> assign(:management_url, WorkerConnection.origin(uri))
      |> assign(
        :page_title,
        if(socket.assigns.live_action == :enrollment, do: "Enrollment policy", else: "Workers")
      )
      |> assign(:bootstrap, nil)
      |> assign(:registered_worker, nil)
      |> assign(:enrollment, Domain.worker_enrollment_settings())
      |> assign(:enrollment_dirty, false)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh_workers, socket) do
    Process.send_after(self(), :refresh_workers, 5000)

    {:noreply,
     assign(socket,
       workers: Domain.list_workers(),
       enrollment:
         if(socket.assigns.enrollment_dirty,
           do: socket.assigns.enrollment,
           else: Domain.worker_enrollment_settings()
         )
     )}
  end

  @impl true
  def handle_event(
        "validate_enrollment",
        %{"enrollment" => %{"allow_anonymous" => value}},
        socket
      )
      when value in ["true", "false"] do
    {:noreply,
     assign(socket, enrollment: %{"allow_anonymous" => value == "true"}, enrollment_dirty: true)}
  end

  def handle_event("save_enrollment", %{"enrollment" => params, "_submission" => intent}, socket)
      when is_map(params) do
    if socket.assigns.live_action == :enrollment and intent == socket.assigns.enrollment_intent do
      case params["allow_anonymous"] do
        value when value in ["true", "false"] ->
          case Domain.mutate(
                 "set_worker_enrollment",
                 %{"allow_anonymous" => value == "true"},
                 "operator",
                 intent
               ) do
            {:ok, settings} ->
              {:noreply,
               socket
               |> assign(
                 enrollment: settings,
                 enrollment_dirty: false,
                 enrollment_intent: Ecto.UUID.generate()
               )
               |> put_flash(:info, "Worker initialization setting saved.")}

            {:error, error} ->
              {:noreply, put_flash(socket, :error, message(error))}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "Invalid initialization setting")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"worker" => params, "_submission" => intent}, socket)
      when is_map(params) do
    if socket.assigns.live_action == :index and intent == socket.assigns.submission_id do
      case WorkerConnections.create(params["name"]) do
        {:ok, connection} ->
          {:noreply,
           socket
           |> show_connection(connection)
           |> assign(:form, to_form(%{"name" => ""}, as: "worker"))
           |> put_flash(:info, "Worker created. Save the connection configuration below.")
           |> push_event("reset_form", %{id: "worker-form"})}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:form, to_form(Map.take(params, ["name"]), as: "worker"))
           |> put_flash(:error, message(error))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_connection", _params, socket),
    do: {:noreply, assign(socket, bootstrap: nil, registered_worker: nil)}

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, "Connection configuration copied.")}

  def handle_event("copy_failed", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Select and copy the configuration text manually.")}

  def handle_event(event, _params, socket) when event in ~w(save rotate_token save_enrollment),
    do: {:noreply, socket}

  defp show_connection(socket, %{"worker" => worker, "token" => token}) do
    assign(socket,
      workers: Domain.list_workers(),
      submission_id: Ecto.UUID.generate(),
      registered_worker: worker,
      bootstrap:
        WorkerConnections.bootstrap(worker, token, socket.assigns.management_url)
        |> WorkerConnection.protect()
    )
  end

  defp message(error), do: error[:message] || error["message"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      servers={Enum.map(@workers, &%{id: &1["id"], name: &1["name"]})}
    >
      <div
        id="workers-workflow"
        phx-hook="NodeWorkflow"
        data-dirty={to_string(@enrollment_dirty)}
        data-reset-key={"#{@submission_id}:#{@enrollment_intent}"}
        class="space-y-6"
      >
        <div>
          <h1>{@page_title}</h1>
          <p class="management-help">
            Add a Worker, connect it, then choose the services it should run.
          </p>
        </div>
        <.card :if={@live_action == :enrollment} title="Enrollment policy">
          <p class="management-help">
            Allow new Workers to register using only this Management address.
            Disabling this does not revoke already registered Workers. This is Worker admission policy, not Management administrator login. New Workers have no services until you configure and publish them.
          </p>
          <.form
            for={%{}}
            id="worker-enrollment-form"
            phx-submit="save_enrollment"
            phx-change="validate_enrollment"
          >
            <input type="hidden" name="_submission" value={@enrollment_intent} />
            <input type="hidden" name="enrollment[allow_anonymous]" value="false" />
            <label class="label">
              <input
                type="checkbox"
                class="checkbox"
                name="enrollment[allow_anonymous]"
                value="true"
                checked={@enrollment["allow_anonymous"]}
              />
              <span>Allow anonymous Worker initialization</span>
            </label>
            <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">Save</button>
          </.form>
        </.card>
        <.link :if={@live_action == :index} navigate="/management/servers/enrollment">Enrollment policy</.link>
        <.link :if={@live_action == :enrollment} navigate="/management/servers">Back to Workers</.link>
        <.card :if={@live_action == :index} title="Workers">
          <p :if={@workers == []} class="management-help">
            No Workers yet. Add one using its name below.
          </p>
          <div class="management-records">
            <table class="table table-striped" id="server-selector-records">
              <thead>
                <tr>
                  <th>Name</th><th>Connection</th><th>Reported services</th><th>Last contact</th><th>
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={worker <- @workers} id={"server-selector-#{worker["id"]}"}>
                  <td>{worker["name"]}</td>
                  <td>{WorkerConnection.status(worker)}</td>
                  <td>{WorkerConnection.services(worker)}</td>
                  <td>{worker["last_seen_at"] || "Never"}</td>
                  <td>
                    <.link
                      navigate={ServicePaths.server_path(worker["id"], :dashboard)}
                      class="btn btn-primary btn-sm"
                    >Manage</.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
        <p :if={@registered_worker} id="registered-worker">
          Registered {@registered_worker["name"]} (<code>{@registered_worker["id"]}</code>).
          <.link navigate={ServicePaths.server_path(@registered_worker["id"], :connection)}>Manage connection</.link>
        </p>
        <WorkerConnection.configuration :if={@bootstrap} bootstrap={@bootstrap} />
        <.card :if={@live_action == :index} title="Register Worker">
          <.form for={@form} id="worker-form" phx-submit="save" phx-hook="ResetForm">
            <input type="hidden" name="_submission" value={@submission_id} />
            <label class="form-control"><span class="label">Name</span><input
              class="input input-bordered"
              name="worker[name]"
              value={@form[:name].value}
              required
              maxlength="128"
            /></label>
            <button type="submit" class="btn btn-primary" phx-disable-with="Adding…">Register Worker</button>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
