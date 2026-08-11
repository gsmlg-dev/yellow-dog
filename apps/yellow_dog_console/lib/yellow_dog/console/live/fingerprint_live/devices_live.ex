defmodule YellowDog.Console.FingerprintLive.DevicesLive do
  @moduledoc "Explicit management-operation boundary for Fingerprint devices."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Fingerprint Devices")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="fingerprint-devices" class="space-y-6">
        <div>
          <h1 class="text-4xl font-bold">Fingerprint Devices</h1>
          <p class="mt-1 text-on-surface-variant">{@selected_server.name || @selected_server.id}</p>
        </div>

        <.card>
          <div class="flex items-start gap-3">
            <.dm_mdi name="information-outline" class="h-6 w-6 text-primary" />
            <div>
              <h2 class="card-title">Management operation unavailable</h2>
              <p class="mt-2 text-on-surface-variant">
                No approved Fingerprint management operation is defined for device inventory.
              </p>
              <.link
                navigate={ServicePaths.server_path(@selected_server.id, :fingerprint_fingerprints)}
                class="link link-primary mt-3 inline-block"
              >
                Fingerprint catalog
              </.link>
            </div>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
