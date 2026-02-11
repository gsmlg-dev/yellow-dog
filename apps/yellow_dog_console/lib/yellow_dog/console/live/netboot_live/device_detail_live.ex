defmodule YellowDog.Console.NetbootLive.DeviceDetailLive do
  @moduledoc "Netboot device detail — full record, profile assignment, state actions."
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @impl true
  def mount(%{"mac" => mac}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:devices")
    end

    profiles =
      safe_call(
        YellowDog.Netboot.Manifest.Store,
        fn ->
          YellowDog.Netboot.Manifest.Store.list_profiles()
        end,
        []
      )

    {:ok,
     socket
     |> assign(page_title: "Device: #{mac}", mac: mac, profiles: profiles)
     |> load_device(mac)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center gap-4">
          <.link navigate="/netboot/devices" class="btn btn-ghost btn-sm">Back</.link>
          <div>
            <h1 class="text-4xl font-bold font-mono">{@mac}</h1>
            <p class="mt-1 text-base-content/70">Netboot device detail</p>
          </div>
        </div>

        <div :if={@device == nil} class="alert alert-warning">
          Device not found
        </div>

        <div :if={@device} class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.card>
            <h2 class="card-title mb-4">Device Info</h2>
            <div class="space-y-2">
              <.info_row label="MAC" value={@device.mac} />
              <.info_row label="Hostname" value={@device.hostname || "-"} />
              <.info_row label="UUID" value={@device.uuid || "-"} />
              <.info_row
                label="Architecture"
                value={if @device.arch, do: to_string(@device.arch), else: "-"}
              />
              <.info_row label="State" value={to_string(@device.state)} />
              <.info_row label="Profile" value={@device.profile_id || "None"} />
              <.info_row label="Install Attempts" value={to_string(@device.install_attempts)} />
              <.info_row label="Last Error" value={@device.last_error || "-"} />
              <.info_row label="First Seen" value={format_datetime(@device.first_seen)} />
              <.info_row label="Last Seen" value={format_datetime(@device.last_seen)} />
              <.info_row
                label="Tags"
                value={Enum.join(@device.tags, ", ") |> then(&if(&1 == "", do: "-", else: &1))}
              />
            </div>
          </.card>

          <.card>
            <h2 class="card-title mb-4">Actions</h2>
            <div class="space-y-3">
              <div>
                <label class="label"><span class="label-text">Assign Profile</span></label>
                <select
                  class="select select-bordered w-full"
                  phx-change="assign_profile"
                  name="profile_id"
                  value={@device.profile_id || ""}
                >
                  <option value="">No profile</option>
                  <option :for={p <- @profiles} value={p.id} selected={p.id == @device.profile_id}>
                    {p.id} — {p.description}
                  </option>
                </select>
              </div>

              <div class="divider"></div>

              <button
                :if={@device.state == :installed}
                phx-click="request_reinstall"
                class="btn btn-warning btn-sm w-full"
                data-confirm="Request reinstall for this device?"
              >
                Request Reinstall
              </button>

              <button
                phx-click="delete_device"
                class="btn btn-error btn-sm w-full"
                data-confirm="Delete this device from the registry?"
              >
                Delete Device
              </button>
            </div>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp info_row(assigns) do
    ~H"""
    <div class="flex justify-between">
      <span class="text-base-content/70">{@label}</span>
      <span class="font-medium">{@value}</span>
    </div>
    """
  end

  @impl true
  def handle_event("assign_profile", %{"profile_id" => ""}, socket) do
    {:noreply, socket}
  end

  def handle_event("assign_profile", %{"profile_id" => profile_id}, socket) do
    case YellowDog.Netboot.Device.Registry.assign_profile(socket.assigns.mac, profile_id) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Profile assigned") |> load_device(socket.assigns.mac)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to assign profile")}
    end
  end

  def handle_event("request_reinstall", _params, socket) do
    case YellowDog.Netboot.Device.Registry.request_reinstall(socket.assigns.mac) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Reinstall requested") |> load_device(socket.assigns.mac)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to request reinstall")}
    end
  end

  def handle_event("delete_device", _params, socket) do
    YellowDog.Netboot.Device.Registry.delete(socket.assigns.mac)

    {:noreply,
     socket
     |> put_flash(:info, "Device deleted")
     |> push_navigate(to: "/netboot/devices")}
  end

  @impl true
  def handle_info({:device_state_changed, _}, socket) do
    {:noreply, load_device(socket, socket.assigns.mac)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_device(socket, mac) do
    case safe_call(
           YellowDog.Netboot.Device.Registry,
           fn ->
             YellowDog.Netboot.Device.Registry.get(mac)
           end,
           {:error, :not_found}
         ) do
      {:ok, device} -> assign(socket, :device, device)
      _ -> assign(socket, :device, nil)
    end
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
