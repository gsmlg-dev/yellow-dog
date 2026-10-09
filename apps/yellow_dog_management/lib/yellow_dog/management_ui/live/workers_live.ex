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
       management_url: nil,
       submission_id: Ecto.UUID.generate(),
       form: to_form(%{"name" => ""}, as: "worker")
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :management_url, WorkerConnection.origin(uri))}
  end

  @impl true
  def handle_info(:refresh_workers, socket) do
    Process.send_after(self(), :refresh_workers, 5000)
    {:noreply, assign(socket, :workers, Domain.list_workers())}
  end

  @impl true
  def handle_event("save", %{"worker" => params, "_submission" => intent}, socket)
      when is_map(params) do
    if intent == socket.assigns.submission_id do
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

  def handle_event("rotate_token", %{"id" => id, "_submission" => intent}, socket) do
    if intent == socket.assigns.submission_id do
      case WorkerConnections.rotate(id) do
        {:ok, connection} ->
          {:noreply,
           socket
           |> show_connection(connection)
           |> put_flash(:info, "Token reset. Update this Worker's connection configuration.")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, message(error))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_connection", _params, socket),
    do: {:noreply, assign(socket, :bootstrap, nil)}

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, "Connection configuration copied.")}

  def handle_event("copy_failed", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Select and copy the configuration text manually.")}

  def handle_event(event, _params, socket) when event in ~w(save rotate_token),
    do: {:noreply, socket}

  defp show_connection(socket, %{"worker" => worker, "token" => token}) do
    assign(socket,
      workers: Domain.list_workers(),
      submission_id: Ecto.UUID.generate(),
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
      <div class="space-y-6">
        <div>
          <h1>Workers</h1>
          <p class="management-help">
            Add a Worker, connect it, then choose the services it should run.
          </p>
        </div>
        <.card title="Workers">
          <p :if={@workers == []} class="management-help">
            No Workers yet. Add one using its name below.
          </p>
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
                  <button
                    class="btn btn-outline btn-sm"
                    type="button"
                    phx-click="rotate_token"
                    phx-value-id={worker["id"]}
                    phx-value-_submission={@submission_id}
                    data-confirm="Reset this Worker's token? Its current token will stop working."
                  >Reset token</button>
                </td>
              </tr>
            </tbody>
          </table>
        </.card>
        <WorkerConnection.configuration :if={@bootstrap} bootstrap={@bootstrap} />
        <.card title="Add Worker">
          <.form for={@form} id="worker-form" phx-submit="save" phx-hook="ResetForm">
            <input type="hidden" name="_submission" value={@submission_id} />
            <label class="form-control"><span class="label">Name</span><input
              class="input input-bordered"
              name="worker[name]"
              value={@form[:name].value}
              required
              maxlength="128"
            /></label>
            <button type="submit" class="btn btn-primary" phx-disable-with="Adding…">Add Worker</button>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
