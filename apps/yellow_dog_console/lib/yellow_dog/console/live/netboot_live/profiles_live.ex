defmodule YellowDog.Console.NetbootLive.ProfilesLive do
  @moduledoc "Management-backed Netboot profiles for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.NetbootLive.ManagementComponents
  alias YellowDog.Console.NetbootLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Boot Profiles",
       subscribed_server_id: nil,
       profiles: [],
       devices: [],
       filtered_profiles: [],
       profile_usage: %{},
       search_query: "",
       sort_field: "profile_id",
       sort_dir: "asc",
       management_error: nil,
       operation_result: nil,
       cached_snapshot?: false,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_profiles(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> apply_filters()}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    dir =
      if socket.assigns.sort_field == field, do: toggle_dir(socket.assigns.sort_dir), else: "asc"

    {:noreply, socket |> assign(sort_field: field, sort_dir: dir) |> apply_filters()}
  end

  def handle_event("export_csv", _params, socket), do: {:noreply, socket}

  def handle_event("set_default", _params, socket) do
    {:noreply,
     ManagementSupport.unavailable(
       socket,
       "Setting a default profile is unavailable through Server management"
     )}
  end

  def handle_event("delete_profile", params, socket) do
    profile_id = params["profile_id"] || params["id"]

    with :ok <- ManagementSupport.mutable(socket),
         {:ok, revision} <- profile_revision(socket.assigns.profiles, profile_id) do
      result =
        ServerManagement.netboot_profiles_delete(
          ManagementSupport.selected_id(socket),
          %{"profile_id" => profile_id},
          ManagementSupport.command_options(revision)
        )

      socket =
        if result.status == :ok do
          profiles = Enum.reject(socket.assigns.profiles, &(&1["profile_id"] == profile_id))
          socket |> assign(:profiles, profiles) |> apply_filters()
        else
          socket
        end

      {:noreply, ManagementSupport.finish(socket, result, "Profile deleted")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_profiles(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="server-netboot-profiles" class="space-y-6">
        <div class="flex items-center justify-between gap-4">
          <ManagementComponents.page_header
            title="Boot Profiles"
            subtitle="Configuration from Management"
            server={@selected_server}
            online?={@service_online?}
            back={ServicePaths.server_path(@selected_server.id, :netboot)}
          />
          <div class="flex gap-2">
            <.link
              navigate={ServicePaths.server_path(@selected_server.id, :netboot_profile_new)}
              class={"btn btn-primary btn-sm #{if !@commands_enabled?, do: "btn-disabled"}"}
            >
              New Profile
            </.link>
            <button id="export-csv" phx-click="export_csv" class="btn btn-outline btn-sm">Export CSV</button>
          </div>
        </div>

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.card>
            <div class="text-sm text-on-surface-variant">Total Profiles</div><div class="text-2xl font-bold">
              {length(@profiles)}
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Assigned Devices</div><div class="text-2xl font-bold">
              {Enum.count(@devices, &(&1["profile_id"] not in [nil, ""]))}
            </div>
          </.card>
        </div>

        <.card>
          <label class="input flex items-center gap-2">
            <.dm_mdi name="magnify" class="h-4 w-4 opacity-70" />
            <input
              name="search"
              value={@search_query}
              phx-change="search"
              phx-debounce="300"
              placeholder="Search profiles"
            />
          </label>
        </.card>

        <.card>
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th phx-click="sort" phx-value-field="profile_id" class="cursor-pointer">
                    Profile ID
                  </th>
                  <th phx-click="sort" phx-value-field="name" class="cursor-pointer">Name</th>
                  <th>Boot asset</th><th>Arguments</th><th>Devices</th><th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@filtered_profiles == []}>
                  <td colspan="6" class="py-8 text-center text-on-surface-variant">
                    No boot profiles in this Server snapshot
                  </td>
                </tr>
                <tr :for={profile <- @filtered_profiles}>
                  <td>
                    <.link
                      navigate={
                        ServicePaths.server_path(
                          @selected_server.id,
                          {:netboot_profile_edit, profile["profile_id"]}
                        )
                      }
                      class="link link-primary font-mono"
                    >
                      {profile["profile_id"]}
                    </.link>
                  </td>
                  <td>{profile["name"]}</td>
                  <td class="font-mono">{profile["boot_asset_id"]}</td>
                  <td>{Enum.join(profile["arguments"] || [], " ")}</td>
                  <td>{Map.get(@profile_usage, profile["profile_id"], 0)}</td>
                  <td>
                    <div class="flex gap-1">
                      <.link
                        navigate={
                          ServicePaths.server_path(
                            @selected_server.id,
                            {:netboot_profile_edit, profile["profile_id"]}
                          )
                        }
                        class="btn btn-ghost btn-xs"
                      >Edit</.link>
                      <.link
                        navigate={clone_path(@selected_server.id, profile["profile_id"])}
                        class="btn btn-ghost btn-xs"
                      >Clone</.link>
                      <button
                        phx-click="delete_profile"
                        phx-value-profile_id={profile["profile_id"]}
                        disabled={!@commands_enabled?}
                        class="btn btn-ghost btn-xs text-error"
                      >Delete</button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  def filter_by_search(profiles, ""), do: profiles

  def filter_by_search(profiles, query) do
    query = String.downcase(query)

    Enum.filter(profiles, fn profile ->
      Enum.any?(
        [
          profile_value(profile, "profile_id"),
          profile_value(profile, "name"),
          profile_value(profile, "boot_asset_id")
        ],
        fn value ->
          String.contains?(String.downcase(value), query)
        end
      )
    end)
  end

  def sort_profiles(profiles, field, dir, usage) do
    sorted =
      Enum.sort_by(profiles, fn profile ->
        if field == "devices" do
          Map.get(usage, profile_value(profile, "profile_id"), 0)
        else
          profile |> profile_value(field) |> String.downcase()
        end
      end)

    if dir == "desc", do: Enum.reverse(sorted), else: sorted
  end

  defp load_profiles(socket, server_id) do
    profiles_result = ServerManagement.netboot_profiles_list(server_id)
    devices_result = ServerManagement.netboot_devices_list(server_id)
    results = [profiles_result, devices_result]
    profiles = ManagementSupport.items(profiles_result)
    devices = ManagementSupport.items(devices_result)
    usage = Enum.frequencies_by(devices, & &1["profile_id"])

    socket
    |> assign(
      page_title: "#{socket.assigns.selected_server.name || server_id} — Boot Profiles",
      profiles: profiles,
      devices: devices,
      profile_usage: usage,
      management_error: ManagementSupport.first_error(results),
      cached_snapshot?: ManagementSupport.cached?(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at),
      commands_enabled?: socket.assigns.service_online?
    )
    |> apply_filters()
  end

  defp apply_filters(socket) do
    profiles =
      socket.assigns.profiles
      |> filter_by_search(socket.assigns.search_query)
      |> sort_profiles(
        socket.assigns.sort_field,
        socket.assigns.sort_dir,
        socket.assigns.profile_usage
      )

    assign(socket, :filtered_profiles, profiles)
  end

  defp profile_revision(profiles, profile_id) do
    ManagementSupport.exact_revision(
      profiles,
      &(&1["profile_id"] == profile_id),
      "Profile"
    )
  end

  defp profile_value(profile, key) when is_map(profile) do
    value = Map.get(profile, key, profile_atom_value(profile, key))
    if is_binary(value), do: value, else: to_string(value || "")
  end

  defp profile_atom_value(profile, "profile_id"),
    do: Map.get(profile, :profile_id, Map.get(profile, :id, ""))

  defp profile_atom_value(profile, "name"),
    do: Map.get(profile, :name, Map.get(profile, :description, ""))

  defp profile_atom_value(profile, "boot_asset_id"),
    do: Map.get(profile, :boot_asset_id, Map.get(profile, :kernel, ""))

  defp profile_atom_value(profile, "description"), do: Map.get(profile, :description, "")
  defp profile_atom_value(profile, "kernel"), do: Map.get(profile, :kernel, "")
  defp profile_atom_value(profile, "initrd"), do: Map.get(profile, :initrd, "")
  defp profile_atom_value(_profile, _key), do: ""

  defp clone_path(server_id, profile_id) do
    ServicePaths.server_path(server_id, :netboot_profile_new) <>
      "?" <> URI.encode_query(%{"clone" => profile_id})
  end

  defp toggle_dir("asc"), do: "desc"
  defp toggle_dir(_dir), do: "asc"
end
