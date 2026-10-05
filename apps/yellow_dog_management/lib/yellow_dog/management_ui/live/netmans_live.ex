defmodule YellowDog.ManagementUI.NetmansLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Domain, ProfileCatalog}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Select a Netman",
       netmans: Domain.list_netmans(),
       form: to_form(default_metadata(), as: "netman")
     )}
  end

  @impl true
  def handle_event("change_metadata", %{"netman" => params}, socket) when is_map(params) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(change_metadata(socket.assigns.form.params, params), as: "netman")
     )}
  end

  def handle_event("save_netman", %{"netman" => params}, socket) when is_map(params) do
    case Domain.mutate("create_netman", metadata_params(params), "operator", Ecto.UUID.generate()) do
      {:ok, _node} ->
        {:noreply,
         socket
         |> assign(
           netmans: Domain.list_netmans(),
           form: to_form(default_metadata(), as: "netman")
         )
         |> put_flash(:info, "Logical Netman registered. Actual runtime state is unknown.")
         |> push_event("reset_form", %{id: "netman-form"})}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(
           :form,
           to_form(change_metadata(socket.assigns.form.params, params), as: "netman")
         )
         |> put_flash(:error, message(error))}
    end
  end

  def handle_event(_event, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid Netman form")}

  def default_metadata do
    %{
      "id" => "",
      "name" => "",
      "profile_name" => "custom",
      "apply_mode" => "managed",
      "features" => %{}
    }
  end

  def change_metadata(current, params) do
    values = Map.merge(current, Map.take(params, ~w(id name profile_name apply_mode features)))

    if values["profile_name"] != current["profile_name"] do
      case Enum.find(
             ProfileCatalog.list_netman_profiles(),
             &(to_string(&1.name) == values["profile_name"])
           ) do
        nil ->
          values

        preset ->
          Map.merge(values, %{
            "apply_mode" => to_string(preset.apply_mode),
            "features" => Map.new(preset.features, fn {key, value} -> {to_string(key), value} end)
          })
      end
    else
      values
    end
  end

  def metadata_params(params) do
    features =
      case params["features"] do
        values when is_map(values) ->
          Map.new(values, fn {key, value} ->
            {key,
             case value do
               "true" -> true
               "false" -> false
               other -> other
             end}
          end)

        nil ->
          %{}

        other ->
          other
      end

    params |> Map.take(~w(id name profile_name apply_mode)) |> Map.put("features", features)
  end

  def message(error), do: error[:message] || error["message"]

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :registration, :boolean, default: false

  def metadata_form(assigns) do
    assigns =
      assign(assigns,
        presets: ProfileCatalog.list_netman_profiles(),
        feature_keys: ProfileCatalog.netman_feature_keys()
      )

    ~H"""
    <.form
      for={@form}
      id={@id}
      phx-submit="save_netman"
      phx-change="change_metadata"
      phx-hook="ResetForm"
      class="space-y-4"
    >
      <label :if={@registration} class="form-control"><span class="label">Netman ID</span><input
        class="input input-bordered"
        name="netman[id]"
        value={text(@form[:id].value)}
        maxlength="64"
        required
      /></label>
      <label class="form-control"><span class="label">Name</span><input
        class="input input-bordered"
        name="netman[name]"
        value={text(@form[:name].value)}
        maxlength="128"
        required
      /></label>
      <label class="form-control"><span class="label">Profile</span><select
        class="select select-bordered"
        name="netman[profile_name]"
      >
        <option
          :for={preset <- @presets}
          value={preset.name}
          selected={to_string(preset.name) == @form[:profile_name].value}
        >
          {preset.name} — {preset.description}
        </option>
      </select></label>
      <label class="form-control"><span class="label">Apply Mode</span><select
        class="select select-bordered"
        name="netman[apply_mode]"
      >
        <option
          :for={mode <- ~w(managed observe_first observe)}
          value={mode}
          selected={mode == @form[:apply_mode].value}
        >
          {mode}
        </option>
      </select></label>
      <fieldset class="space-y-2">
        <legend class="font-semibold">Features</legend>
        <label :for={key <- @feature_keys} class="flex items-center gap-2">
          <input type="hidden" name={"netman[features][#{key}]"} value="false" />
          <input
            class="checkbox checkbox-primary"
            type="checkbox"
            name={"netman[features][#{key}]"}
            value="true"
            checked={enabled?(@form[:features].value, key)}
          />
          <span>{key}</span>
        </label>
      </fieldset>
      <p class="text-sm text-on-surface-variant">
        Presets and feature flags describe desired metadata, not connected runtime support or agent startup.
      </p>
      <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">{if @registration,
        do: "Register",
        else: "Save Metadata"}</button>
    </.form>
    """
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  defp enabled?(features, key) when is_map(features),
    do: features[to_string(key)] in [true, "true"]

  defp enabled?(_features, _key), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      netmans={Enum.map(@netmans, &%{id: &1["id"], name: &1["name"]})}
    >
      <div class="max-w-7xl space-y-6">
        <div>
          <h1 class="text-3xl font-bold">Select a Netman</h1><p class="text-on-surface-variant">
            Manage PostgreSQL desired configuration. Actual runtime state is unknown.
          </p>
        </div>
        <.card title="Registered Netman Instances">
          <p :if={@netmans == []} id="netman-empty">No Netman instances registered</p>
          <div :if={@netmans != []} class="overflow-x-auto">
            <table class="table table-striped" id="netman-selector-records">
              <thead>
                <tr>
                  <th>Netman</th><th>Profile</th><th>Apply Mode</th><th>Status</th><th>Runtime</th><th>
                    Open
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={node <- @netmans} id={"netman-selector-#{node["id"]}"}>
                  <td>
                    <div class="font-semibold">{node["name"]}</div><code>{node["id"]}</code>
                  </td><td>{node["profile_name"]}</td><td>{node["apply_mode"]}</td><td>
                    {node["status"]}
                  </td><td>{node["actual_state"]}</td>
                  <td>
                    <.link
                      navigate={ServicePaths.netman_path(node["id"], :overview)}
                      class="btn btn-primary btn-sm"
                    >Manage</.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
        <.card title="Register Netman">
          <.metadata_form form={@form} id="netman-form" registration />
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
