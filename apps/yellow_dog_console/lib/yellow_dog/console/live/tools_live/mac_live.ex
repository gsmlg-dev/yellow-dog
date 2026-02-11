defmodule YellowDog.Console.ToolsLive.MacLive do
  @moduledoc """
  MAC address vendor lookup tool using the `gsmlg_mac` hex package.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts

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

        <form phx-submit="lookup" class="flex gap-2 mb-6">
          <input
            type="text"
            name="mac"
            value={@query}
            placeholder="Enter MAC address (e.g. 00:00:0A:BB:28:FC)"
            class="input input-bordered flex-1"
            autofocus
          />
          <button type="submit" phx-disable-with="Looking up..." class="btn btn-primary">
            Lookup
          </button>
        </form>

        <div :if={@error} class="alert alert-error mb-4">
          <span>{@error}</span>
        </div>

        <div :if={!@result && !@error && @query == ""} class="text-center py-12 text-base-content/50">
          Enter a MAC address to identify its manufacturer
        </div>

        <div :if={@result} class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div class="stat bg-base-200 rounded-box">
            <div class="stat-title">Manufacturer</div>
            <div class="stat-value text-lg">{@result.full_name}</div>
          </div>
          <div class="stat bg-base-200 rounded-box">
            <div class="stat-title">Short Name</div>
            <div class="stat-value text-lg">{@result.short_name}</div>
          </div>
          <div class="stat bg-base-200 rounded-box">
            <div class="stat-title">MAC Address</div>
            <div class="stat-value text-lg font-mono">{@result.mac}</div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("lookup", %{"mac" => mac}, socket) do
    mac = String.trim(mac)

    if mac == "" do
      {:noreply, assign(socket, result: nil, error: nil, query: "")}
    else
      case GSMLG.MAC.lookup_vendor(mac) do
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
      end
    end
  end
end
