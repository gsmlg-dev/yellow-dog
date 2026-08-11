defmodule YellowDog.Console.NetbootLive.Index do
  @moduledoc "Management-backed Netboot overview for one selected Server."

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
       page_title: "Netboot Dashboard",
       subscribed_server_id: nil,
       profiles: [],
       devices: [],
       assets: [],
       transfers: [],
       management_error: nil,
       cached_snapshot?: false,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_overview(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_overview(socket, ManagementSupport.selected_id(socket))}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_overview(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="server-netboot-overview" class="space-y-6">
        <div class="flex items-center justify-between gap-4">
          <ManagementComponents.page_header
            title="Netboot Dashboard"
            subtitle="Network boot provisioning"
            server={@selected_server}
            online?={@service_online?}
          />
          <div class="flex gap-2">
            <.link
              navigate={ServicePaths.server_path(@selected_server.id, :netboot_log)}
              class="btn btn-ghost btn-sm"
            >
              Boot Log
            </.link>
            <button phx-click="refresh" class="btn btn-outline btn-sm">Refresh</button>
          </div>
        </div>

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-4">
          <.link navigate={ServicePaths.server_path(@selected_server.id, :netboot_devices)}>
            <.card>
              <div class="text-sm text-on-surface-variant">Devices</div><div class="text-2xl font-bold">
                {length(@devices)}
              </div>
            </.card>
          </.link>
          <.link navigate={ServicePaths.server_path(@selected_server.id, :netboot_profiles)}>
            <.card>
              <div class="text-sm text-on-surface-variant">Profiles</div><div class="text-2xl font-bold">
                {length(@profiles)}
              </div>
            </.card>
          </.link>
          <.link navigate={ServicePaths.server_path(@selected_server.id, :netboot_tftp)}>
            <.card>
              <div class="text-sm text-on-surface-variant">Boot assets</div><div class="text-2xl font-bold">
                {length(@assets)}
              </div>
            </.card>
          </.link>
          <.card>
            <div class="text-sm text-on-surface-variant">Transfers</div><div class="text-2xl font-bold">
              {length(@transfers)}
            </div>
          </.card>
        </div>

        <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
          <.card>
            <div class="mb-4 flex items-center justify-between">
              <h2 class="card-title">Boot Profiles</h2>
              <.link
                navigate={ServicePaths.server_path(@selected_server.id, :netboot_profiles)}
                class="link link-primary"
              >View all</.link>
            </div>
            <div :if={@profiles == []} class="text-on-surface-variant">
              No profiles in this Server snapshot
            </div>
            <div
              :for={profile <- @profiles}
              class="flex items-center justify-between border-b border-outline-variant py-2 last:border-0"
            >
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
              <span>{profile["name"]}</span>
            </div>
          </.card>

          <.card>
            <div class="mb-4 flex items-center justify-between">
              <h2 class="card-title">Boot Assets</h2>
              <.link
                navigate={ServicePaths.server_path(@selected_server.id, :netboot_tftp)}
                class="link link-primary"
              >Details</.link>
            </div>
            <div :if={@assets == []} class="text-on-surface-variant">
              No boot assets in this Server snapshot
            </div>
            <div
              :for={asset <- @assets}
              class="flex items-center justify-between border-b border-outline-variant py-2 last:border-0"
            >
              <span class="font-mono">{asset["filename"]}</span>
              <span class="text-sm text-on-surface-variant">{format_size(asset["size"])}</span>
            </div>
          </.card>
        </div>

        <.card>
          <div class="mb-4 flex items-center justify-between">
            <h2 class="card-title">Devices</h2>
            <.link
              navigate={ServicePaths.server_path(@selected_server.id, :netboot_devices)}
              class="link link-primary"
            >View all</.link>
          </div>
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>MAC</th><th>Device ID</th><th>Profile</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@devices == []}>
                  <td colspan="3" class="py-8 text-center text-on-surface-variant">
                    No devices in this Server snapshot
                  </td>
                </tr>
                <tr :for={device <- @devices}>
                  <td>
                    <.link
                      navigate={
                        ServicePaths.server_path(
                          @selected_server.id,
                          {:netboot_device, device["mac"]}
                        )
                      }
                      class="link link-primary font-mono"
                    >
                      {device["mac"]}
                    </.link>
                  </td>
                  <td>{device["device_id"]}</td>
                  <td>{device["profile_id"]}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp load_overview(socket, server_id) do
    profiles_result = ServerManagement.netboot_profiles_list(server_id)
    devices_result = ServerManagement.netboot_devices_list(server_id)
    assets_result = ServerManagement.netboot_assets_list(server_id)
    transfers_result = ServerManagement.netboot_transfers_list(server_id)
    results = [profiles_result, devices_result, assets_result, transfers_result]

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — Netboot",
      profiles: ManagementSupport.items(profiles_result),
      devices: ManagementSupport.items(devices_result),
      assets: ManagementSupport.items(assets_result),
      transfers: ManagementSupport.items(transfers_result),
      management_error: ManagementSupport.first_error(results),
      cached_snapshot?: ManagementSupport.cached?(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at)
    )
  end

  defp format_size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_size(bytes) when is_integer(bytes) and bytes >= 1_024,
    do: "#{Float.round(bytes / 1_024, 1)} KB"

  defp format_size(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_size(_bytes), do: "-"
end
