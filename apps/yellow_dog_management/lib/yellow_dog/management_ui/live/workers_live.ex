defmodule YellowDog.ManagementUI.WorkersLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Domain, ProfileCatalog}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Select a Server",
       workers: Domain.list_workers(),
       profiles: ProfileCatalog.list_server_profiles(),
       form: to_form(%{"id" => "", "name" => "", "profile_name" => "custom"}, as: "worker")
     )}
  end

  @impl true
  def handle_event("save", %{"worker" => params}, socket) do
    result =
      Domain.mutate(
        "create_worker",
        Map.put(Map.take(params, ~w(id name profile_name)), "expected_capabilities", ["dns"]),
        "operator",
        Ecto.UUID.generate()
      )

    case result do
      {:ok, _worker} ->
        {:noreply,
         socket
         |> assign(
           workers: Domain.list_workers(),
           form: to_form(%{"id" => "", "name" => "", "profile_name" => "custom"}, as: "worker")
         )
         |> put_flash(:info, "Logical Worker registered. Actual runtime state is unknown.")
         |> push_event("reset_form", %{id: "worker-form"})}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(form: to_form(params, as: "worker"))
         |> put_flash(:error, error[:message] || error["message"])}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      servers={Enum.map(@workers, &%{id: &1["id"], name: &1["name"]})}
    >
      <div class="max-w-7xl space-y-6">
        <div>
          <h1 class="text-3xl font-bold">Select a Server</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            Choose a logical Worker to manage. Configuration is available without a connected runtime.
          </p>
        </div>
        <.card title="Registered Servers">
          <div :if={@workers == []} class="py-10 text-center text-on-surface-variant">
            <.dm_mdi name="server-off" class="mx-auto mb-3 h-12 w-12" />
            <p class="text-lg">No servers registered</p>
            <p class="mt-1 text-sm">Register a logical Worker before opening service pages.</p>
          </div>
          <div :if={@workers != []} class="overflow-x-auto">
            <table class="table table-striped" id="server-selector-records">
              <thead>
                <tr>
                  <th>Server</th><th>Profile</th><th>Capabilities</th><th>Status</th><th>Runtime</th><th>
                    Open
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={worker <- @workers}
                  id={"server-selector-#{worker["id"]}"}
                  data-profile-name={worker["profile_name"]}
                >
                  <td>
                    <div class="font-semibold">{worker["name"]}</div><div class="font-mono text-xs">
                      {worker["id"]}
                    </div>
                  </td>
                  <td>{worker["profile_name"]}</td>
                  <td>{Enum.join(worker["expected_capabilities"], ", ")}</td>
                  <td>{worker["status"]}</td>
                  <td>{worker["actual_state"]}</td>
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
        <.card title="Register Server">
          <.form for={@form} id="worker-form" phx-submit="save" phx-hook="ResetForm" class="space-y-4">
            <label class="form-control"><span class="label">Worker ID</span><input
              class="input input-bordered"
              name="worker[id]"
              value={@form[:id].value}
              required
              maxlength="64"
            /></label>
            <label class="form-control"><span class="label">Name</span><input
              class="input input-bordered"
              name="worker[name]"
              value={@form[:name].value}
              required
              maxlength="128"
            /></label>
            <label class="form-control"><span class="label">Profile</span><select
              id="worker-profile"
              class="select select-bordered"
              name="worker[profile_name]"
            >
              <option
                :for={profile <- @profiles}
                value={profile.name}
                selected={to_string(profile.name) == @form[:profile_name].value}
              >
                {profile.name} — {profile.description}
              </option>
            </select></label>
            <p class="text-sm text-on-surface-variant">
              Profiles are descriptive catalog metadata, not service enablement. Selecting a profile
              does not change expected capabilities, configure services or start agents.
              Capabilities are declared expectations, not observed runtime support.
            </p>
            <button type="submit" class="btn btn-primary" phx-disable-with="Registering…">Register</button>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
