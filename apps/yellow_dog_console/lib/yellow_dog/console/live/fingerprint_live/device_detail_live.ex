defmodule YellowDog.Console.FingerprintLive.DeviceDetailLive do
  @moduledoc "Device detail page — shows full fingerprint and profile info for a MAC."
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @impl true
  def mount(%{"mac" => mac}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "fingerprint:devices")
    end

    {:ok,
     socket
     |> assign(
       page_title: "Device: #{mac}",
       mac: mac,
       service_running: service_running?(YellowDog.Fingerprint)
     )
     |> load_device(mac)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <.service_alert :if={not @service_running} service="Fingerprint" />

        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-4xl font-bold font-mono">{@mac}</h1>
            <p :if={@device} class="mt-2 text-base-content/70">
              {if @device.oui_vendor, do: @device.oui_vendor, else: "Unknown Vendor"} — {if @device.hostname,
                do: @device.hostname,
                else: "no hostname"}
            </p>
          </div>
          <.link navigate="/fingerprint/devices" class="btn btn-ghost btn-sm">
            ← Back to Devices
          </.link>
        </div>

        <div :if={!@device} class="alert alert-warning">
          <span>Device not found in registry</span>
        </div>

        <div :if={@device} class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <.card title="Identity">
            <dl class="space-y-3">
              <div class="flex justify-between">
                <dt class="text-base-content/70">MAC Address</dt>
                <dd class="font-mono">{@device.mac}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/70">OUI Vendor</dt>
                <dd>{@device.oui_vendor || "-"}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/70">Hostname</dt>
                <dd>{@device.hostname || "-"}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/70">Profile</dt>
                <dd>
                  <.badge :if={@device.profile_id} color="info" size="sm">
                    {@device.profile_id}
                  </.badge>
                  <.badge :if={!@device.profile_id} color="warning" size="sm">unknown</.badge>
                </dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/70">Confidence</dt>
                <dd>{@device.profile_confidence}%</dd>
              </div>
            </dl>
          </.card>

          <.card title="Network">
            <dl class="space-y-3">
              <div>
                <dt class="text-base-content/70 mb-1">IPv4 Addresses</dt>
                <dd :if={@device.ipv4_addresses == []} class="text-base-content/50">none</dd>
                <dd :for={ip <- @device.ipv4_addresses} class="font-mono text-sm">{ip}</dd>
              </div>
              <div>
                <dt class="text-base-content/70 mb-1">IPv6 Addresses</dt>
                <dd :if={@device.ipv6_addresses == []} class="text-base-content/50">none</dd>
                <dd :for={ip <- @device.ipv6_addresses} class="font-mono text-sm">{ip}</dd>
              </div>
            </dl>
          </.card>

          <.card title="Fingerprints">
            <dl class="space-y-3">
              <div class="flex justify-between">
                <dt class="text-base-content/70">DHCPv4 Fingerprint</dt>
                <dd class="font-mono text-xs truncate max-w-[200px]">
                  {@device.fingerprint_v4_id || "-"}
                </dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/70">DHCPv6 Fingerprint</dt>
                <dd class="font-mono text-xs truncate max-w-[200px]">
                  {@device.fingerprint_v6_id || "-"}
                </dd>
              </div>
              <div :if={@device.duid} class="flex justify-between">
                <dt class="text-base-content/70">DUID</dt>
                <dd class="font-mono text-xs truncate max-w-[200px]">
                  {Base.encode16(@device.duid, case: :lower)}
                </dd>
              </div>
            </dl>
          </.card>

          <.card title="Observation History">
            <dl class="space-y-3">
              <div class="flex justify-between">
                <dt class="text-base-content/70">First Seen</dt>
                <dd>{format_datetime(@device.first_seen)}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/70">Last Seen</dt>
                <dd>{format_datetime(@device.last_seen)}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/70">Observations</dt>
                <dd class="font-bold">{@device.observation_count}</dd>
              </div>
            </dl>
          </.card>
        </div>

        <.card :if={@profile} title="Device Profile">
          <dl class="grid grid-cols-2 md:grid-cols-3 gap-4">
            <div>
              <dt class="text-base-content/70 text-sm">Name</dt>
              <dd class="font-bold">{@profile.name}</dd>
            </div>
            <div>
              <dt class="text-base-content/70 text-sm">OS Family</dt>
              <dd>{@profile.os_family || "-"}</dd>
            </div>
            <div>
              <dt class="text-base-content/70 text-sm">OS Version</dt>
              <dd>{@profile.os_version || "-"}</dd>
            </div>
            <div>
              <dt class="text-base-content/70 text-sm">Device Type</dt>
              <dd>
                <.badge color="primary" size="sm">{@profile.device_type}</.badge>
              </dd>
            </div>
            <div>
              <dt class="text-base-content/70 text-sm">Vendor</dt>
              <dd>{@profile.vendor || "-"}</dd>
            </div>
            <div>
              <dt class="text-base-content/70 text-sm">Source</dt>
              <dd>
                <.badge color={source_color(@profile.source)} size="sm">{@profile.source}</.badge>
              </dd>
            </div>
          </dl>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:device_updated, device}, socket) do
    if device.mac == socket.assigns.mac do
      {:noreply, load_device(socket, socket.assigns.mac)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "fingerprint:devices")
    :ok
  end

  # --- Private ---

  defp load_device(socket, mac) do
    device =
      safe_call(
        YellowDog.Fingerprint,
        fn -> YellowDog.Fingerprint.get_device(mac) end,
        :not_found
      )

    {device, profile} =
      case device do
        {:ok, d} ->
          p =
            if d.profile_id do
              case safe_call(
                     YellowDog.Fingerprint,
                     fn ->
                       YellowDog.Fingerprint.lookup(
                         d.fingerprint_v4_id || d.fingerprint_v6_id || ""
                       )
                     end,
                     :unknown
                   ) do
                {:ok, profile} -> profile
                _ -> nil
              end
            end

          {d, p}

        _ ->
          {nil, nil}
      end

    assign(socket, device: device, profile: profile)
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp source_color(:local), do: "info"
  defp source_color(:fingerbank), do: "primary"
  defp source_color(:user_override), do: "success"
  defp source_color(_), do: "ghost"
end
