defmodule YellowDog.Console.NetbootLive.DeviceDetailLive do
  @moduledoc "Netboot device detail — full record, profile assignment, state actions."
  use YellowDog.Console, :live_view

  import YellowDog.Console.NetbootComponents
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
        <div class="breadcrumbs text-sm">
          <ul>
            <li><.link navigate="/netboot">Netboot</.link></li>
            <li><.link navigate="/netboot/devices">Devices</.link></li>
            <li class="font-mono">{@mac}</li>
          </ul>
        </div>

        <div class="flex items-center gap-4">
          <div>
            <div class="flex items-center gap-2">
              <h1 id="device-mac" class="text-4xl font-bold font-mono">{@mac}</h1>
              <button
                id="copy-mac"
                phx-hook="CopyToClipboard"
                data-target="device-mac"
                class="btn btn-ghost btn-sm"
                aria-label="Copy MAC address"
              >
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" />
                </svg>
              </button>
            </div>
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
              <.info_row
                label="IP Address"
                value={if @device.ip_address, do: format_ip(@device.ip_address), else: "-"}
              />
              <.info_row
                label="Rescue Mode"
                value={if @device.rescue_mode, do: "Enabled", else: "Off"}
              />
              <.info_row label="Install Attempts" value={to_string(@device.install_attempts)} />
              <.info_row label="Last Error" value={@device.last_error || "-"} />
              <.info_row label="First Seen" value={format_datetime_full(@device.first_seen)} />
              <.info_row label="Last Seen" value={format_datetime_full(@device.last_seen)} />
            </div>

            <div class="mt-4">
              <label class="label"><span class="label-text font-medium">Tags</span></label>
              <div class="flex flex-wrap gap-1 mb-2">
                <span
                  :for={tag <- @device.tags}
                  class="badge badge-outline gap-1"
                >
                  {tag}
                  <button
                    phx-click="remove_tag"
                    phx-value-tag={tag}
                    class="text-xs opacity-70 hover:opacity-100"
                    aria-label={"Remove tag #{tag}"}
                  >
                    &times;
                  </button>
                </span>
                <span :if={@device.tags == []} class="text-base-content/50 text-sm">No tags</span>
              </div>
              <form phx-submit="add_tag" class="flex gap-2">
                <input
                  type="text"
                  name="tag"
                  placeholder="Add tag..."
                  class="input input-bordered input-sm flex-1"
                  value=""
                />
                <button type="submit" class="btn btn-outline btn-sm">Add</button>
              </form>
            </div>
          </.card>

          <.card :if={@device.hardware_info != %{}}>
            <h2 class="card-title mb-4">Hardware Info</h2>
            <div class="space-y-2">
              <.info_row
                :for={{key, val} <- @device.hardware_info}
                label={humanize_key(key)}
                value={to_string(val)}
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
                :if={@device.state in [:installed, :failed]}
                phx-click="request_reinstall"
                class="btn btn-warning btn-sm w-full"
                data-confirm="Request reinstall for this device?"
              >
                Request Reinstall
              </button>

              <button
                phx-click="toggle_rescue"
                class={[
                  "btn btn-sm w-full",
                  if(@device.rescue_mode,
                    do: "btn-active btn-accent",
                    else: "btn-outline btn-accent"
                  )
                ]}
              >
                {if @device.rescue_mode, do: "Disable Rescue Mode", else: "Boot to Rescue"}
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

        <.card :if={@device && @device.state_history != []}>
          <h2 class="card-title mb-4">State History</h2>
          <ul class="timeline timeline-vertical timeline-compact">
            <li :for={{entry, idx} <- Enum.with_index(Enum.reverse(@device.state_history))}>
              <hr :if={idx > 0} />
              <div class="timeline-start text-sm text-base-content/70">
                {format_datetime_full(entry.at)}
              </div>
              <div class="timeline-middle">
                <div class={[
                  "w-3 h-3 rounded-full",
                  history_dot_color(entry.state)
                ]}>
                </div>
              </div>
              <div class="timeline-end timeline-box">
                <.state_badge state={entry.state} />
              </div>
              <hr :if={idx < length(@device.state_history) - 1} />
            </li>
          </ul>
        </.card>

        <div class="text-xs text-base-content/50 flex justify-end">
          <span :if={connected?(@socket)} class="flex items-center gap-1">
            <span class="w-2 h-2 bg-success rounded-full animate-pulse"></span> Live
          </span>
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

  def handle_event("toggle_rescue", _params, socket) do
    enabled = not (socket.assigns.device && socket.assigns.device.rescue_mode)

    result =
      safe_call(
        YellowDog.Netboot.Device.Registry,
        fn -> YellowDog.Netboot.Device.Registry.set_rescue_mode(socket.assigns.mac, enabled) end,
        {:error, :unavailable}
      )

    case result do
      {:ok, _} ->
        msg = if enabled, do: "Rescue mode enabled", else: "Rescue mode disabled"
        {:noreply, socket |> put_flash(:info, msg) |> load_device(socket.assigns.mac)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle rescue mode")}
    end
  end

  def handle_event("add_tag", %{"tag" => tag}, socket) do
    tag = String.trim(tag)

    if tag != "" && socket.assigns.device do
      new_tags = Enum.uniq(socket.assigns.device.tags ++ [tag])

      case safe_call(
             YellowDog.Netboot.Device.Registry,
             fn ->
               YellowDog.Netboot.Device.Registry.update_tags(socket.assigns.mac, new_tags)
             end,
             {:error, :unavailable}
           ) do
        {:ok, _} ->
          {:noreply, load_device(socket, socket.assigns.mac)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to add tag")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_tag", %{"tag" => tag}, socket) do
    if socket.assigns.device do
      new_tags = List.delete(socket.assigns.device.tags, tag)

      case safe_call(
             YellowDog.Netboot.Device.Registry,
             fn ->
               YellowDog.Netboot.Device.Registry.update_tags(socket.assigns.mac, new_tags)
             end,
             {:error, :unavailable}
           ) do
        {:ok, _} ->
          {:noreply, load_device(socket, socket.assigns.mac)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to remove tag")}
      end
    else
      {:noreply, socket}
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

  defp history_dot_color(:discovered), do: "bg-neutral"
  defp history_dot_color(:booting), do: "bg-warning"
  defp history_dot_color(:installing), do: "bg-info"
  defp history_dot_color(:installed), do: "bg-success"
  defp history_dot_color(:failed), do: "bg-error"
  defp history_dot_color(:reinstall_requested), do: "bg-warning"
  defp history_dot_color(_), do: "bg-neutral"

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

  defp format_ip(ip) when is_tuple(ip), do: to_string(:inet.ntoa(ip))
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: "-"

  defp humanize_key(key) when is_binary(key) do
    key |> String.replace("_", " ") |> String.capitalize()
  end

  defp humanize_key(key) when is_atom(key), do: humanize_key(to_string(key))
  defp humanize_key(key), do: to_string(key)
end
