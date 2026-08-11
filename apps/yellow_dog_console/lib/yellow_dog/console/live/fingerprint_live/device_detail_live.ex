defmodule YellowDog.Console.FingerprintLive.DeviceDetailLive do
  @moduledoc "Explicit management-operation boundary for one Fingerprint device."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(%{"mac" => mac}, _session, socket) do
    {:ok, assign(socket, page_title: "Fingerprint Device", mac: mac)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="fingerprint-device" class="space-y-6">
        <div class="flex items-center gap-3">
          <.link
            navigate={ServicePaths.server_path(@selected_server.id, :fingerprint_devices)}
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Back"
          >
            <.dm_mdi name="arrow-left" class="h-5 w-5" />
          </.link>
          <div>
            <h1 class="text-4xl font-bold">Fingerprint Device</h1>
            <p class="mt-1 text-on-surface-variant">{@selected_server.name || @selected_server.id}</p>
          </div>
        </div>

        <.card>
          <div class="font-mono text-sm">{@mac}</div>
          <h2 class="card-title mt-4">Management operation unavailable</h2>
          <p class="mt-2 text-on-surface-variant">
            No approved Fingerprint management operation is defined for device details.
          </p>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
