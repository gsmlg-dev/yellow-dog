defmodule YellowDog.ManagementUI.ToolsLive.MacLive do
  @moduledoc """
  MAC address vendor lookup tool using the `gsmlg_mac` hex package.
  """
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.MacDatabase
  alias YellowDog.ManagementUI.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "MAC Lookup",
       query: "",
       result: nil,
       error: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-4xl">
        <h1 class="text-2xl font-bold mb-4">MAC Address Lookup</h1>

        <form id="mac-lookup-form" phx-submit="lookup" class="flex gap-2 mb-6">
          <input
            type="text"
            name="mac"
            aria-label="MAC address"
            value={@query}
            placeholder="Enter MAC address (e.g. 00:00:0A:BB:28:FC)"
            class="input flex-1"
            autofocus
          />
          <button type="submit" phx-disable-with="Looking up..." class="btn btn-primary">
            Lookup
          </button>
        </form>

        <div :if={@error} class="alert alert-error mb-4">
          <span>{@error}</span>
        </div>

        <div
          :if={!@result && !@error && @query == ""}
          class="text-center py-12 text-on-surface-variant"
        >
          Enter a MAC address to identify its manufacturer
        </div>

        <div :if={@result} id="mac-lookup-result" class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div class="card card-bordered bg-surface">
            <div class="card-body">
              <div class="text-lg font-bold">{@result.full_name}</div>
            </div>
          </div>
          <div class="card card-bordered bg-surface">
            <div class="card-body">
              <div class="text-lg font-bold">{@result.short_name}</div>
            </div>
          </div>
          <div class="card card-bordered bg-surface">
            <div class="card-body">
              <div class="text-lg font-bold font-mono">{@result.mac}</div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("lookup", %{"mac" => mac}, socket)
      when is_binary(mac) and byte_size(mac) <= 128 do
    mac = String.trim(mac)

    if mac == "" do
      {:noreply, assign(socket, result: nil, error: nil, query: "")}
    else
      server = Application.get_env(:yellow_dog_management, :mac_database_server, MacDatabase)

      lookup =
        Application.get_env(:yellow_dog_management, :mac_lookup, &MacDatabase.lookup(&1, server))

      case lookup.(mac) do
        {:ok, short_name, full_name} ->
          {:noreply,
           assign(socket,
             result: %{short_name: short_name, full_name: full_name, mac: mac},
             error: nil,
             query: mac
           )}

        :error ->
          {:noreply,
           assign(socket,
             result: nil,
             error: "No vendor found for this MAC address",
             query: mac
           )}

        {:error, :invalid_mac} ->
          {:noreply, assign(socket, result: nil, error: "Invalid MAC address", query: mac)}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             result: nil,
             error: "Lookup unavailable: #{inspect(reason)}",
             query: mac
           )}
      end
    end
  end

  def handle_event("lookup", _params, socket) do
    {:noreply, assign(socket, result: nil, error: "Invalid MAC address")}
  end
end
