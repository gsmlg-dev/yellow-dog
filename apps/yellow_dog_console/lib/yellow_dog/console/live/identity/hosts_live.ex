defmodule YellowDog.Console.IdentityLive.HostsLive do
  use YellowDog.Console, :live_view

  alias YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "identity:hosts")
    end

    {:ok,
     socket
     |> assign(:page_title, "All Hosts")
     |> assign(:filter, "all")
     |> assign(:search, "")
     |> load_hosts()}
  end

  @impl true
  def handle_info({:host_registered, _}, socket), do: {:noreply, load_hosts(socket)}
  def handle_info({:host_updated, _}, socket), do: {:noreply, load_hosts(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:filter, status) |> load_hosts()}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:search, query) |> load_hosts()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_hosts(socket)}
  end

  defp load_hosts(socket) do
    filter = socket.assigns.filter
    search = socket.assigns.search

    hosts =
      ServiceHelper.safe_call(
        YellowDogIdentity,
        fn ->
          case filter do
            "pending" -> YellowDogIdentity.list_hosts(status: :pending)
            "approved" -> YellowDogIdentity.list_hosts(status: :approved)
            "revoked" -> YellowDogIdentity.list_hosts(status: :revoked)
            _ -> YellowDogIdentity.list_hosts()
          end
        end,
        []
      )

    hosts =
      if search != "" do
        q = String.downcase(search)
        Enum.filter(hosts, fn h -> String.contains?(String.downcase(h.hostname), q) end)
      else
        hosts
      end

    assign(socket, :hosts, hosts)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Host Registry</h1>
          <button class="btn btn-sm btn-ghost" phx-click="refresh">
            ↻
          </button>
        </div>

        <div class="flex items-center gap-4">
          <div class="flex gap-2">
            <button
              :for={s <- ["all", "pending", "approved", "revoked"]}
              class={["btn btn-sm", if(@filter == s, do: "btn-primary", else: "btn-ghost")]}
              phx-click="filter"
              phx-value-status={s}
            >
              {String.capitalize(s)}
            </button>
          </div>
          <form phx-change="search" class="flex-1 max-w-xs">
            <input
              type="text"
              name="q"
              value={@search}
              placeholder="Search hostname..."
              class="input input-sm w-full"
              phx-debounce="300"
            />
          </form>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-striped w-full">
            <thead>
              <tr>
                <th>Hostname</th>
                <th>Status</th>
                <th>Trust Level</th>
                <th>Provider</th>
                <th>Age Recipient</th>
                <th>Created</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={host <- @hosts} class="hover">
                <td class="font-mono">{host.hostname}</td>
                <td>
                  <span class={status_badge_class(host.status)}>
                    {host.status}
                  </span>
                </td>
                <td><span class="badge badge-outline badge-sm">{host.trust_level}</span></td>
                <td>{host.trust_provider}</td>
                <td class="font-mono text-xs max-w-[200px] truncate">{host.age_recipient}</td>
                <td class="text-sm">{format_time(host.created_at)}</td>
                <td>
                  <.link navigate={~p"/identity/hosts/#{host.id}"} class="btn btn-xs btn-ghost">
                    Details
                  </.link>
                </td>
              </tr>
              <tr :if={@hosts == []}>
                <td colspan="7" class="text-center text-on-surface-variant py-8">
                  No hosts registered
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp status_badge_class(:pending), do: "badge badge-warning"
  defp status_badge_class(:approved), do: "badge badge-success"
  defp status_badge_class(:revoked), do: "badge badge-error"
  defp status_badge_class(_), do: "badge"

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_time(_), do: "-"
end
