defmodule YellowDog.Console.IdentityLive.AuditLive do
  use YellowDog.Console, :live_view

  alias YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Identity Audit Log")
     |> assign(:filter_event, nil)
     |> assign(:filter_host, "")
     |> load_entries()}
  end

  @impl true
  def handle_event("filter", %{"event" => event, "host" => host}, socket) do
    event_filter = if event == "", do: nil, else: event
    host_filter = String.trim(host)

    {:noreply,
     socket
     |> assign(:filter_event, event_filter)
     |> assign(:filter_host, host_filter)
     |> load_entries()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_entries(socket)}
  end

  defp load_entries(socket) do
    opts = [limit: 200]

    opts =
      case socket.assigns[:filter_event] do
        nil -> opts
        event -> Keyword.put(opts, :event, event)
      end

    opts =
      case socket.assigns[:filter_host] do
        "" -> opts
        nil -> opts
        host_id -> Keyword.put(opts, :host_id, host_id)
      end

    entries =
      ServiceHelper.safe_call(
        YellowDogIdentity,
        fn -> YellowDogIdentity.audit_log(opts) end,
        []
      )

    assign(socket, :entries, entries)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Audit Log</h1>
          <button class="btn btn-sm btn-ghost" phx-click="refresh">
            ↻
          </button>
        </div>

        <form phx-change="filter" class="flex gap-2 items-end">
          <div class="form-control">
            <label class="label"><span class="label-text">Event Type</span></label>
            <select name="event" class="select select-sm select-bordered">
              <option value="">All Events</option>
              <option value="host.registered" selected={@filter_event == "host.registered"}>
                host.registered
              </option>
              <option value="host.approved" selected={@filter_event == "host.approved"}>
                host.approved
              </option>
              <option value="host.revoked" selected={@filter_event == "host.revoked"}>
                host.revoked
              </option>
              <option value="host.key_rotated" selected={@filter_event == "host.key_rotated"}>
                host.key_rotated
              </option>
              <option value="host.deleted" selected={@filter_event == "host.deleted"}>
                host.deleted
              </option>
            </select>
          </div>
          <div class="form-control">
            <label class="label"><span class="label-text">Host ID</span></label>
            <input
              type="text"
              name="host"
              value={@filter_host}
              placeholder="Filter by host ID..."
              class="input input-sm input-bordered w-64"
            />
          </div>
        </form>

        <div :if={@entries == []} class="text-center py-12 text-base-content/50">
          No audit entries found
        </div>

        <div :if={@entries != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Timestamp</th>
                <th>Event</th>
                <th>Host ID</th>
                <th>Details</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @entries}>
                <td class="font-mono text-xs whitespace-nowrap">{entry.timestamp}</td>
                <td>
                  <span class={event_badge_class(entry.event)}>{entry.event}</span>
                </td>
                <td>
                  <.link
                    navigate={~p"/identity/hosts/#{entry.host_id}"}
                    class="link link-primary font-mono text-xs"
                  >
                    {String.slice(entry.host_id, 0, 8)}...
                  </.link>
                </td>
                <td class="font-mono text-xs max-w-[400px] truncate">{entry.details}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp event_badge_class("host.registered"), do: "badge badge-info badge-sm"
  defp event_badge_class("host.approved"), do: "badge badge-success badge-sm"
  defp event_badge_class("host.revoked"), do: "badge badge-error badge-sm"
  defp event_badge_class("host.key_rotated"), do: "badge badge-warning badge-sm"
  defp event_badge_class("host.deleted"), do: "badge badge-error badge-outline badge-sm"
  defp event_badge_class(_), do: "badge badge-sm"
end
