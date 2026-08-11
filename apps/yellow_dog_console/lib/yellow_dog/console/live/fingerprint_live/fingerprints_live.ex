defmodule YellowDog.Console.FingerprintLive.FingerprintsLive do
  @moduledoc "Explicit management-operation boundary for the Fingerprint catalog."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Fingerprints")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="fingerprint-fingerprints" class="space-y-6">
        <div>
          <h1 class="text-4xl font-bold">Fingerprints</h1>
          <p class="mt-1 text-on-surface-variant">{@selected_server.name || @selected_server.id}</p>
        </div>

        <.card>
          <div class="flex items-start gap-3">
            <.dm_mdi name="information-outline" class="h-6 w-6 text-primary" />
            <div>
              <h2 class="card-title">Management operation unavailable</h2>
              <p class="mt-2 text-on-surface-variant">
                No approved Fingerprint management operation is defined for fingerprint data.
              </p>
              <.link
                navigate={ServicePaths.server_path(@selected_server.id, :fingerprint_devices)}
                class="link link-primary mt-3 inline-block"
              >
                Devices
              </.link>
            </div>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
