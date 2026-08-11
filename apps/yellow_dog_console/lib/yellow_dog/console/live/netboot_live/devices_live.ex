defmodule YellowDog.Console.NetbootLive.DevicesLive do
  @moduledoc "Management-backed Netboot devices for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.NetbootLive.ManagementComponents
  alias YellowDog.Console.NetbootLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Netboot Devices",
       subscribed_server_id: nil,
       devices: [],
       profiles: [],
       filtered_devices: [],
       search_query: "",
       profile_filter: "all",
       sort_field: "mac",
       sort_dir: "asc",
       management_error: nil,
       operation_result: nil,
       cached_snapshot?: false,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id} = params, _uri, socket) do
    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign(:profile_filter, params["profile"] || socket.assigns.profile_filter)

    {:noreply, if(connected?(socket), do: load_devices(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> apply_filters()}
  end

  def handle_event("filter_profile", params, socket) do
    profile = params["profile"] || params["value"] || "all"
    {:noreply, socket |> assign(:profile_filter, profile) |> apply_filters()}
  end

  def handle_event("filter_state", _params, socket), do: {:noreply, socket}

  def handle_event("sort", %{"field" => field}, socket) do
    dir =
      if socket.assigns.sort_field == field, do: toggle_dir(socket.assigns.sort_dir), else: "asc"

    {:noreply, socket |> assign(sort_field: field, sort_dir: dir) |> apply_filters()}
  end

  def handle_event("export_csv", _params, socket), do: {:noreply, socket}

  def handle_event("assign_profile", params, socket) do
    device_id = params["device_id"]
    profile_id = params["profile_id"] || params["profile"]

    with :ok <- ManagementSupport.mutable(socket),
         %{} = device <- Enum.find(socket.assigns.devices, &(&1["device_id"] == device_id)),
         {:ok, revision} <- device_revision(socket.assigns.devices, device_id) do
      payload = %{
        "device_id" => device["device_id"],
        "profile_id" => profile_id,
        "mac" => device["mac"]
      }

      result =
        ServerManagement.netboot_devices_put(
          ManagementSupport.selected_id(socket),
          payload,
          ManagementSupport.command_options(revision)
        )

      {:noreply,
       socket
       |> put_device(result)
       |> ManagementSupport.finish(result, "Device profile updated")}
    else
      nil -> {:noreply, put_flash(socket, :error, "Device is not present in this snapshot")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete_device", params, socket) do
    device_id = params["device_id"] || params["id"]

    with :ok <- ManagementSupport.mutable(socket),
         {:ok, revision} <- device_revision(socket.assigns.devices, device_id) do
      result =
        ServerManagement.netboot_devices_delete(
          ManagementSupport.selected_id(socket),
          %{"device_id" => device_id},
          ManagementSupport.command_options(revision)
        )

      socket =
        if result.status == :ok do
          devices = Enum.reject(socket.assigns.devices, &(&1["device_id"] == device_id))
          socket |> assign(:devices, devices) |> apply_filters()
        else
          socket
        end

      {:noreply, ManagementSupport.finish(socket, result, "Device deleted")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event(event, _params, socket)
      when event in [
             "quick_reinstall",
             "quick_rescue",
             "bulk_assign_profile",
             "bulk_add_tag",
             "bulk_delete"
           ] do
    {:noreply,
     ManagementSupport.unavailable(socket, "This action is unavailable through Server management")}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_devices(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="server-netboot-devices" class="space-y-6">
        <div class="flex items-center justify-between gap-4">
          <ManagementComponents.page_header
            title="Netboot Devices"
            subtitle="Assignments from Management"
            server={@selected_server}
            online?={@service_online?}
            back={ServicePaths.server_path(@selected_server.id, :netboot)}
          />
          <button id="export-csv" phx-click="export_csv" class="btn btn-outline btn-sm">Export CSV</button>
        </div>

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.card>
            <div class="text-sm text-on-surface-variant">Total devices</div><div class="text-2xl font-bold">
              {length(@devices)}
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Assigned</div><div class="text-2xl font-bold">
              {Enum.count(@devices, &(&1["profile_id"] not in [nil, ""]))}
            </div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Unassigned</div><div class="text-2xl font-bold">
              {Enum.count(@devices, &(&1["profile_id"] in [nil, ""]))}
            </div>
          </.card>
        </div>

        <.card>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <label class="input flex items-center gap-2">
              <.dm_mdi name="magnify" class="h-4 w-4 opacity-70" />
              <input
                name="search"
                value={@search_query}
                phx-change="search"
                phx-debounce="300"
                placeholder="Search by device ID or MAC"
              />
            </label>
            <select name="profile" phx-change="filter_profile" class="select select-bordered w-full">
              <option value="all" selected={@profile_filter == "all"}>All profiles</option>
              <option value="unassigned" selected={@profile_filter == "unassigned"}>
                Unassigned
              </option>
              <option
                :for={profile <- @profiles}
                value={profile["profile_id"]}
                selected={@profile_filter == profile["profile_id"]}
              >
                {profile["name"]}
              </option>
            </select>
          </div>
        </.card>

        <.card>
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th phx-click="sort" phx-value-field="mac" class="cursor-pointer">MAC</th>
                  <th phx-click="sort" phx-value-field="device_id" class="cursor-pointer">
                    Device ID
                  </th>
                  <th>Profile</th><th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@filtered_devices == []}>
                  <td colspan="4" class="py-8 text-center text-on-surface-variant">
                    No devices in this Server snapshot
                  </td>
                </tr>
                <tr :for={device <- @filtered_devices}>
                  <td>
                    <.link
                      navigate={
                        ServicePaths.server_path(
                          @selected_server.id,
                          {:netboot_device, device["mac"]}
                        )
                      }
                      class="link link-primary font-mono"
                    >{device["mac"]}</.link>
                  </td>
                  <td>{device["device_id"]}</td>
                  <td>
                    <form phx-change="assign_profile" id={"assign-profile-#{device["device_id"]}"}>
                      <input type="hidden" name="device_id" value={device["device_id"]} />
                      <select
                        name="profile_id"
                        disabled={!@commands_enabled?}
                        class="select select-bordered select-sm"
                      >
                        <option value="">Unassigned</option>
                        <option
                          :for={profile <- @profiles}
                          value={profile["profile_id"]}
                          selected={profile["profile_id"] == device["profile_id"]}
                        >
                          {profile["name"]}
                        </option>
                      </select>
                    </form>
                  </td>
                  <td>
                    <div class="flex gap-1">
                      <.link
                        navigate={
                          ServicePaths.server_path(
                            @selected_server.id,
                            {:netboot_device, device["mac"]}
                          )
                        }
                        class="btn btn-ghost btn-xs"
                      >Details</.link>
                      <button
                        phx-click="delete_device"
                        phx-value-device_id={device["device_id"]}
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

  def filter_by_search(devices, ""), do: devices

  def filter_by_search(devices, query) do
    query = String.downcase(query)

    Enum.filter(devices, fn device ->
      Enum.any?(
        [
          device_value(device, "device_id"),
          device_value(device, "mac"),
          device_value(device, "profile_id")
        ],
        fn value ->
          String.contains?(String.downcase(value), query)
        end
      )
    end)
  end

  def filter_by_profile(devices, "all"), do: devices

  def filter_by_profile(devices, "unassigned"),
    do: Enum.filter(devices, &(device_value(&1, "profile_id") == ""))

  def filter_by_profile(devices, profile_id),
    do: Enum.filter(devices, &(device_value(&1, "profile_id") == profile_id))

  def sort_devices(devices, field, dir) do
    sorted = Enum.sort_by(devices, &(device_value(&1, field) |> String.downcase()))
    if dir == "desc", do: Enum.reverse(sorted), else: sorted
  end

  defp load_devices(socket, server_id) do
    devices_result = ServerManagement.netboot_devices_list(server_id)
    profiles_result = ServerManagement.netboot_profiles_list(server_id)
    results = [devices_result, profiles_result]

    socket
    |> assign(
      page_title: "#{socket.assigns.selected_server.name || server_id} — Netboot Devices",
      devices: ManagementSupport.items(devices_result),
      profiles: ManagementSupport.items(profiles_result),
      management_error: ManagementSupport.first_error(results),
      cached_snapshot?: ManagementSupport.cached?(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at),
      commands_enabled?: socket.assigns.service_online?
    )
    |> apply_filters()
  end

  defp apply_filters(socket) do
    devices =
      socket.assigns.devices
      |> filter_by_search(socket.assigns.search_query)
      |> filter_by_profile(socket.assigns.profile_filter)
      |> sort_devices(socket.assigns.sort_field, socket.assigns.sort_dir)

    assign(socket, :filtered_devices, devices)
  end

  defp device_revision(devices, device_id) do
    ManagementSupport.exact_revision(devices, &(&1["device_id"] == device_id), "Device")
  end

  defp put_device(socket, %ManagementResult{status: :ok, value: %{"resource" => device}}) do
    devices = [
      device | Enum.reject(socket.assigns.devices, &(&1["device_id"] == device["device_id"]))
    ]

    socket |> assign(:devices, devices) |> apply_filters()
  end

  defp put_device(socket, _result), do: socket

  defp device_value(device, key) when is_map(device) do
    value = Map.get(device, key, device_atom_value(device, key))
    if is_binary(value), do: value, else: to_string(value || "")
  end

  defp device_atom_value(device, "device_id"), do: Map.get(device, :device_id, "")
  defp device_atom_value(device, "mac"), do: Map.get(device, :mac, "")
  defp device_atom_value(device, "profile_id"), do: Map.get(device, :profile_id, "")
  defp device_atom_value(device, "hostname"), do: Map.get(device, :hostname, "")
  defp device_atom_value(device, "state"), do: Map.get(device, :state, "")
  defp device_atom_value(_device, _key), do: ""

  defp toggle_dir("asc"), do: "desc"
  defp toggle_dir(_dir), do: "asc"
end
