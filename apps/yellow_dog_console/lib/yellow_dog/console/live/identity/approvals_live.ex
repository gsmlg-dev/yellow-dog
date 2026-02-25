defmodule YellowDog.Console.IdentityLive.ApprovalsLive do
  use YellowDog.Console, :live_view

  alias YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "identity:hosts")
    end

    {:ok,
     socket
     |> assign(:page_title, "Pending Approvals")
     |> assign(:selected, MapSet.new())
     |> load_pending()}
  end

  @impl true
  def handle_info({:host_registered, _}, socket),
    do: {:noreply, load_pending(socket) |> assign(:selected, MapSet.new())}

  def handle_info({:host_updated, _}, socket),
    do: {:noreply, load_pending(socket) |> assign(:selected, MapSet.new())}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    case YellowDogIdentity.approve(id, "console-operator") do
      {:ok, _} -> {:noreply, load_pending(socket) |> put_flash(:info, "Host approved")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to approve")}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    case YellowDogIdentity.revoke(id, "console-operator", "rejected via console") do
      {:ok, _} -> {:noreply, load_pending(socket) |> put_flash(:info, "Host rejected")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to reject")}
    end
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all", _params, socket) do
    ids = Enum.map(socket.assigns.pending, & &1.id)
    {:noreply, assign(socket, :selected, MapSet.new(ids))}
  end

  def handle_event("select_none", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  def handle_event("bulk_approve", _params, socket) do
    selected = socket.assigns.selected
    count = MapSet.size(selected)

    Enum.each(selected, fn id ->
      YellowDogIdentity.approve(id, "console-operator")
    end)

    {:noreply,
     socket
     |> assign(:selected, MapSet.new())
     |> load_pending()
     |> put_flash(:info, "#{count} host(s) approved")}
  end

  def handle_event("bulk_reject", _params, socket) do
    selected = socket.assigns.selected
    count = MapSet.size(selected)

    Enum.each(selected, fn id ->
      YellowDogIdentity.revoke(id, "console-operator", "bulk rejected via console")
    end)

    {:noreply,
     socket
     |> assign(:selected, MapSet.new())
     |> load_pending()
     |> put_flash(:info, "#{count} host(s) rejected")}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_pending(socket)}
  end

  defp load_pending(socket) do
    pending =
      ServiceHelper.safe_call(
        YellowDogIdentity,
        fn ->
          YellowDogIdentity.list_hosts(status: :pending)
        end,
        []
      )

    assign(socket, :pending, pending)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Pending Approvals</h1>
          <button class="btn btn-sm btn-ghost" phx-click="refresh">
            ↻
          </button>
        </div>

        <div :if={@pending != [] && MapSet.size(@selected) > 0} class="flex gap-2 items-center">
          <span class="text-sm text-base-content/70">
            {MapSet.size(@selected)} selected
          </span>
          <button
            class="btn btn-sm btn-success"
            phx-click="bulk_approve"
            data-confirm={"Approve #{MapSet.size(@selected)} host(s)?"}
          >
            Approve Selected
          </button>
          <button
            class="btn btn-sm btn-error btn-outline"
            phx-click="bulk_reject"
            data-confirm={"Reject #{MapSet.size(@selected)} host(s)?"}
          >
            Reject Selected
          </button>
          <button class="btn btn-sm btn-ghost" phx-click="select_none">
            Clear
          </button>
        </div>

        <div :if={@pending != []} class="flex gap-2">
          <button class="btn btn-xs btn-ghost" phx-click="select_all">Select All</button>
          <button class="btn btn-xs btn-ghost" phx-click="select_none">Select None</button>
        </div>

        <div :if={@pending == []} class="text-center py-12 text-base-content/50">
          No pending approvals
        </div>

        <div :for={host <- @pending} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  checked={MapSet.member?(@selected, host.id)}
                  phx-click="toggle_select"
                  phx-value-id={host.id}
                />
                <div>
                  <h3 class="font-bold text-lg">{host.hostname}</h3>
                  <p class="text-sm text-base-content/70">
                    Trust: <span class="badge badge-outline badge-sm">{host.trust_level}</span>
                    via {host.trust_provider}
                  </p>
                </div>
              </div>
              <div class="flex gap-2">
                <button
                  class="btn btn-sm btn-success"
                  phx-click="approve"
                  phx-value-id={host.id}
                >
                  Approve
                </button>
                <button
                  class="btn btn-sm btn-error btn-outline"
                  phx-click="reject"
                  phx-value-id={host.id}
                >
                  Reject
                </button>
                <.link navigate={~p"/identity/hosts/#{host.id}"} class="btn btn-sm btn-ghost">
                  Details
                </.link>
              </div>
            </div>
            <div class="mt-2 grid grid-cols-2 md:grid-cols-4 gap-2 text-sm">
              <div>
                <span class="text-base-content/50">Fingerprint:</span>
                <span class="font-mono text-xs">{host.key_fingerprint}</span>
              </div>
              <div>
                <span class="text-base-content/50">Role:</span>
                {host.role || "-"}
              </div>
              <div>
                <span class="text-base-content/50">Datacenter:</span>
                {host.datacenter || "-"}
              </div>
              <div>
                <span class="text-base-content/50">Registered:</span>
                {format_time(host.created_at)}
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_time(_), do: "-"
end
