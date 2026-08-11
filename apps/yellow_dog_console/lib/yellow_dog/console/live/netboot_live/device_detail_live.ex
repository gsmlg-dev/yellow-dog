defmodule YellowDog.Console.NetbootLive.DeviceDetailLive do
  @moduledoc "Management-backed detail for a Netboot device on one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.NetbootLive.ManagementComponents
  alias YellowDog.Console.NetbootLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(%{"mac" => mac}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Device #{mac}",
       subscribed_server_id: nil,
       requested_mac: mac,
       device: nil,
       devices: [],
       profiles: [],
       management_error: nil,
       operation_result: nil,
       cached_snapshot?: false,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id, "mac" => mac}, _uri, socket) do
    socket = socket |> ManagementSupport.subscribe(server_id) |> assign(:requested_mac, mac)
    {:noreply, if(connected?(socket), do: load_device(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("assign_profile", params, socket) do
    profile_id = params["profile_id"]

    with :ok <- ManagementSupport.mutable(socket),
         %{} = device <- socket.assigns.device,
         true <-
           valid_profile?(socket.assigns.profiles, profile_id) ||
             {:error, "Select an available profile"},
         {:ok, revision} <- device_revision(socket.assigns.devices, device["device_id"]) do
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

  def handle_event("delete_device", _params, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         %{} = device <- socket.assigns.device,
         {:ok, revision} <- device_revision(socket.assigns.devices, device["device_id"]) do
      result =
        ServerManagement.netboot_devices_delete(
          ManagementSupport.selected_id(socket),
          %{"device_id" => device["device_id"]},
          ManagementSupport.command_options(revision)
        )

      socket = if result.status == :ok, do: assign(socket, :device, nil), else: socket
      {:noreply, ManagementSupport.finish(socket, result, "Device deleted")}
    else
      nil -> {:noreply, put_flash(socket, :error, "Device is not present in this snapshot")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event(event, _params, socket)
      when event in ["request_reinstall", "toggle_rescue", "add_tag", "remove_tag"] do
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
     |> load_device(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="server-netboot-device-detail" class="space-y-6">
        <ManagementComponents.page_header
          title="Netboot Device"
          subtitle={@requested_mac}
          server={@selected_server}
          online?={@service_online?}
          back={ServicePaths.server_path(@selected_server.id, :netboot_devices)}
        />

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />

        <div :if={is_nil(@device)} class="alert alert-warning">
          Device not found in the selected Server snapshot.
        </div>

        <div :if={@device} class="grid grid-cols-1 gap-6 lg:grid-cols-2">
          <.card>
            <h2 class="card-title mb-4">Device information</h2>
            <dl class="space-y-3">
              <div>
                <dt class="text-sm text-on-surface-variant">MAC</dt><dd class="font-mono">
                  {@device["mac"]}
                </dd>
              </div>
              <div>
                <dt class="text-sm text-on-surface-variant">Device ID</dt><dd class="font-mono">
                  {@device["device_id"]}
                </dd>
              </div>
              <div>
                <dt class="text-sm text-on-surface-variant">Profile</dt><dd>
                  {@device["profile_id"]}
                </dd>
              </div>
            </dl>
          </.card>

          <.card>
            <h2 class="card-title mb-4">Profile assignment</h2>
            <form id="device-profile-form" phx-change="assign_profile">
              <select
                name="profile_id"
                disabled={!@commands_enabled?}
                class="select select-bordered w-full"
              >
                <option
                  :for={profile <- @profiles}
                  value={profile["profile_id"]}
                  selected={profile["profile_id"] == @device["profile_id"]}
                >
                  {profile["name"]} ({profile["profile_id"]})
                </option>
              </select>
            </form>
            <div class="mt-4 flex gap-2">
              <button phx-click="request_reinstall" disabled class="btn btn-outline btn-sm">Reinstall unavailable</button>
              <button phx-click="toggle_rescue" disabled class="btn btn-outline btn-sm">Rescue unavailable</button>
            </div>
          </.card>

          <.card class="lg:col-span-2">
            <div class="flex items-center justify-between">
              <div>
                <h2 class="card-title">Remove device</h2><p class="text-on-surface-variant">
                  Delete this device assignment from the selected Server.
                </p>
              </div>
              <button
                phx-click="delete_device"
                disabled={!@commands_enabled?}
                class="btn btn-error btn-sm"
              >Delete Device</button>
            </div>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_device(socket, server_id) do
    devices_result = ServerManagement.netboot_devices_list(server_id)
    profiles_result = ServerManagement.netboot_profiles_list(server_id)
    results = [devices_result, profiles_result]
    devices = ManagementSupport.items(devices_result)

    assign(socket,
      page_title:
        "#{socket.assigns.selected_server.name || server_id} — #{socket.assigns.requested_mac}",
      devices: devices,
      profiles: ManagementSupport.items(profiles_result),
      device: Enum.find(devices, &device_matches?(&1, socket.assigns.requested_mac)),
      management_error: ManagementSupport.first_error(results),
      cached_snapshot?: ManagementSupport.cached?(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at),
      commands_enabled?: socket.assigns.service_online?
    )
  end

  defp device_matches?(device, requested) do
    String.downcase(device["mac"] || "") == String.downcase(requested) or
      device["device_id"] == requested
  end

  defp valid_profile?(profiles, profile_id),
    do: is_binary(profile_id) and Enum.any?(profiles, &(&1["profile_id"] == profile_id))

  defp device_revision(devices, device_id) do
    ManagementSupport.exact_revision(devices, &(&1["device_id"] == device_id), "Device")
  end

  defp put_device(socket, %ManagementResult{status: :ok, value: %{"resource" => device}}) do
    devices = [
      device | Enum.reject(socket.assigns.devices, &(&1["device_id"] == device["device_id"]))
    ]

    assign(socket, devices: devices, device: device)
  end

  defp put_device(socket, _result), do: socket
end
