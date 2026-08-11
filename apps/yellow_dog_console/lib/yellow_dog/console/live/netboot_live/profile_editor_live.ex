defmodule YellowDog.Console.NetbootLive.ProfileEditorLive do
  @moduledoc "Management-backed editor for a Netboot profile on one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.NetbootLive.ManagementComponents
  alias YellowDog.Console.NetbootLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @empty_form %{
    "profile_id" => "",
    "name" => "",
    "boot_asset_id" => "",
    "arguments" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Boot Profile",
       subscribed_server_id: nil,
       mode: :new,
       profile_id: nil,
       clone_source: nil,
       profiles: [],
       assets: [],
       devices: [],
       device_count: 0,
       form: to_form(@empty_form, as: "profile"),
       errors: %{},
       management_error: nil,
       operation_result: nil,
       cached_snapshot?: false,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id} = params, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_editor(socket, server_id, params), else: socket)}
  end

  @impl true
  def handle_event("validate", %{"profile" => params}, socket) do
    {:noreply,
     assign(socket,
       form: to_form(normalize_params(params, socket.assigns), as: "profile"),
       errors: validate_profile(params, socket.assigns.mode)
     )}
  end

  def handle_event("save", %{"profile" => params}, socket) do
    normalized = normalize_params(params, socket.assigns)
    errors = validate_profile(normalized, socket.assigns.mode)

    with :ok <- ManagementSupport.mutable(socket),
         true <- errors == %{} || {:error, "Please correct the profile fields"},
         {:ok, revision} <- expected_revision(socket) do
      result =
        ServerManagement.netboot_profiles_put(
          ManagementSupport.selected_id(socket),
          profile_payload(normalized),
          ManagementSupport.command_options(revision)
        )

      socket =
        socket
        |> put_profile(result)
        |> assign(:errors, %{})
        |> ManagementSupport.finish(result, "Profile saved")

      {:noreply, socket}
    else
      {:error, message} ->
        {:noreply, socket |> assign(:errors, errors) |> put_flash(:error, message)}
    end
  end

  def handle_event("delete_profile", _params, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         profile_id when is_binary(profile_id) <- socket.assigns.profile_id,
         {:ok, revision} <- profile_revision(socket.assigns.profiles, profile_id) do
      result =
        ServerManagement.netboot_profiles_delete(
          ManagementSupport.selected_id(socket),
          %{"profile_id" => profile_id},
          ManagementSupport.command_options(revision)
        )

      socket =
        if result.status == :ok do
          update(
            socket,
            :profiles,
            &Enum.reject(&1, fn profile -> profile["profile_id"] == profile_id end)
          )
        else
          socket
        end

      {:noreply, ManagementSupport.finish(socket, result, "Profile deleted")}
    else
      nil -> {:noreply, put_flash(socket, :error, "Profile is not present in this snapshot")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    params =
      case socket.assigns.mode do
        :edit -> %{"server_id" => server_id, "id" => socket.assigns.profile_id}
        :new -> %{"server_id" => server_id}
      end

    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_editor(server_id, params)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="server-netboot-profile-editor" class="space-y-6">
        <ManagementComponents.page_header
          title={if @mode == :new, do: "New Boot Profile", else: "Edit Boot Profile"}
          subtitle={if @profile_id, do: @profile_id, else: "New profile"}
          server={@selected_server}
          online?={@service_online?}
          back={ServicePaths.server_path(@selected_server.id, :netboot_profiles)}
        />

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />

        <p :if={@clone_source} class="text-info">
          Cloned from <span class="font-mono">{@clone_source}</span>
        </p>
        <p :if={@mode == :edit && @device_count > 0} class="text-warning">
          {@device_count} device(s) currently use this profile.
        </p>

        <.card>
          <form id="netboot-profile-form" phx-submit="save" phx-change="validate" class="space-y-4">
            <label class="form-control w-full">
              <span class="label-text">Profile ID</span>
              <input
                name="profile[profile_id]"
                value={@form[:profile_id].value}
                disabled={@mode == :edit}
                class={"input input-bordered w-full #{if @errors[:profile_id], do: "input-error"}"}
              />
              <span :if={@errors[:profile_id]} class="text-sm text-error">{@errors[:profile_id]}</span>
            </label>

            <label class="form-control w-full">
              <span class="label-text">Name</span>
              <input
                name="profile[name]"
                value={@form[:name].value}
                class={"input input-bordered w-full #{if @errors[:name], do: "input-error"}"}
              />
              <span :if={@errors[:name]} class="text-sm text-error">{@errors[:name]}</span>
            </label>

            <label class="form-control w-full">
              <span class="label-text">Boot asset</span>
              <select
                name="profile[boot_asset_id]"
                class={"select select-bordered w-full #{if @errors[:boot_asset_id], do: "select-error"}"}
              >
                <option value="">Select an asset</option>
                <option
                  :for={asset <- @assets}
                  value={asset["asset_id"]}
                  selected={asset["asset_id"] == @form[:boot_asset_id].value}
                >
                  {asset["filename"]} ({asset["asset_id"]})
                </option>
              </select>
              <span :if={@errors[:boot_asset_id]} class="text-sm text-error">{@errors[:boot_asset_id]}</span>
            </label>

            <label class="form-control w-full">
              <span class="label-text">Arguments</span>
              <textarea name="profile[arguments]" class="textarea textarea-bordered w-full" rows="5">{@form[:arguments].value}</textarea>
              <span class="text-sm text-on-surface-variant">One argument per line or comma-separated.</span>
            </label>

            <div class="flex justify-between gap-2">
              <button
                :if={@mode == :edit}
                type="button"
                phx-click="delete_profile"
                disabled={!@commands_enabled?}
                class="btn btn-error btn-sm"
              >Delete Profile</button>
              <span :if={@mode == :new}></span>
              <div class="flex gap-2">
                <.link
                  navigate={ServicePaths.server_path(@selected_server.id, :netboot_profiles)}
                  class="btn btn-ghost"
                >Cancel</.link>
                <button type="submit" disabled={!@commands_enabled?} class="btn btn-primary">
                  {if @mode == :new, do: "Create Profile", else: "Save Changes"}
                </button>
              </div>
            </div>
          </form>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  def validate_profile(params, mode) do
    errors = %{}
    profile_id = String.trim(params["profile_id"] || params["id"] || "")
    name = String.trim(params["name"] || params["description"] || "")
    boot_asset_id = String.trim(params["boot_asset_id"] || params["kernel"] || "")

    errors =
      if mode == :new and profile_id == "",
        do: Map.put(errors, :profile_id, "Profile ID is required"),
        else: errors

    errors =
      if mode == :new and profile_id != "" and
           not Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, profile_id),
         do:
           Map.put(errors, :profile_id, "Use lowercase letters, numbers, hyphens, or underscores"),
         else: errors

    errors = if name == "", do: Map.put(errors, :name, "Name is required"), else: errors

    if boot_asset_id == "",
      do: Map.put(errors, :boot_asset_id, "Boot asset is required"),
      else: errors
  end

  defp load_editor(socket, server_id, params) do
    profiles_result = ServerManagement.netboot_profiles_list(server_id)
    assets_result = ServerManagement.netboot_assets_list(server_id)
    devices_result = ServerManagement.netboot_devices_list(server_id)
    results = [profiles_result, assets_result, devices_result]
    profiles = ManagementSupport.items(profiles_result)
    assets = ManagementSupport.items(assets_result)
    devices = ManagementSupport.items(devices_result)
    {mode, profile_id, clone_source, form_data} = editor_state(params, profiles)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — Boot Profile",
      mode: mode,
      profile_id: profile_id,
      clone_source: clone_source,
      profiles: profiles,
      assets: assets,
      devices: devices,
      device_count: Enum.count(devices, &(&1["profile_id"] == profile_id)),
      form: to_form(form_data, as: "profile"),
      errors: %{},
      management_error: ManagementSupport.first_error(results),
      cached_snapshot?: ManagementSupport.cached?(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at),
      commands_enabled?: socket.assigns.service_online?
    )
  end

  defp editor_state(%{"id" => profile_id}, profiles) do
    profile = Enum.find(profiles, &(&1["profile_id"] == profile_id))

    {:edit, profile_id, nil,
     profile_to_form(profile || Map.put(@empty_form, "profile_id", profile_id))}
  end

  defp editor_state(%{"clone" => source_id}, profiles) do
    case Enum.find(profiles, &(&1["profile_id"] == source_id)) do
      nil ->
        {:new, nil, nil, @empty_form}

      profile ->
        {:new, nil, source_id,
         profile |> profile_to_form() |> Map.put("profile_id", "#{source_id}-copy")}
    end
  end

  defp editor_state(_params, _profiles), do: {:new, nil, nil, @empty_form}

  defp profile_to_form(profile) do
    %{
      "profile_id" => profile["profile_id"] || "",
      "name" => profile["name"] || "",
      "boot_asset_id" => profile["boot_asset_id"] || "",
      "arguments" => Enum.join(profile["arguments"] || [], "\n")
    }
  end

  defp normalize_params(params, assigns) do
    %{
      "profile_id" =>
        if(assigns.mode == :edit,
          do: assigns.profile_id,
          else: String.trim(params["profile_id"] || params["id"] || "")
        ),
      "name" => String.trim(params["name"] || params["description"] || ""),
      "boot_asset_id" => String.trim(params["boot_asset_id"] || params["kernel"] || ""),
      "arguments" => params["arguments"] || params["kernel_args"] || ""
    }
  end

  defp profile_payload(params) do
    %{
      "profile_id" => params["profile_id"],
      "name" => params["name"],
      "boot_asset_id" => params["boot_asset_id"],
      "arguments" => ManagementSupport.csv(params["arguments"])
    }
  end

  defp expected_revision(%{assigns: %{mode: :new}}), do: {:ok, nil}

  defp expected_revision(socket) do
    profile_revision(socket.assigns.profiles, socket.assigns.profile_id)
  end

  defp profile_revision(profiles, profile_id) do
    ManagementSupport.exact_revision(profiles, &(&1["profile_id"] == profile_id), "Profile")
  end

  defp put_profile(socket, %ManagementResult{status: :ok, value: %{"resource" => profile}}) do
    profiles = [
      profile | Enum.reject(socket.assigns.profiles, &(&1["profile_id"] == profile["profile_id"]))
    ]

    assign(socket,
      profiles: profiles,
      mode: :edit,
      profile_id: profile["profile_id"],
      form: to_form(profile_to_form(profile), as: "profile")
    )
  end

  defp put_profile(socket, _result), do: socket
end
