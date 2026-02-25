defmodule YellowDog.Console.IdentityLive.Index do
  use YellowDog.Console, :live_view

  alias YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "identity:hosts")
    end

    {:ok,
     socket
     |> assign(:page_title, "Identity Registry")
     |> assign(:export_preview, nil)
     |> assign(:export_format, "yaml")
     |> load_data()}
  end

  @impl true
  def handle_info({:host_registered, _host}, socket), do: {:noreply, load_data(socket)}
  def handle_info({:host_updated, _host}, socket), do: {:noreply, load_data(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_event("preview_export", %{"format" => format}, socket) do
    export =
      ServiceHelper.safe_call(
        YellowDogIdentity,
        fn ->
          case format do
            "sops" -> YellowDogIdentity.export_recipients(format: :sops)
            _ -> YellowDogIdentity.export_recipients()
          end
        end,
        ""
      )

    {:noreply, socket |> assign(:export_preview, export) |> assign(:export_format, format)}
  end

  def handle_event("close_export", _params, socket) do
    {:noreply, assign(socket, :export_preview, nil)}
  end

  defp load_data(socket) do
    stats =
      ServiceHelper.safe_call(
        YellowDogIdentity,
        fn -> YellowDogIdentity.stats() end,
        default_stats()
      )

    socket
    |> assign(:stats, stats)
    |> assign(:service_running, service_running?())
  end

  defp default_stats do
    %{
      total: 0,
      pending: 0,
      approved: 0,
      revoked: 0,
      trust_levels: %{},
      providers: %{},
      active_tokens: 0,
      total_tokens: 0
    }
  end

  defp service_running? do
    Process.whereis(YellowDogIdentity.Registry) != nil
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Host Identity Registry</h1>
          <div class="flex items-center gap-2">
            <span class={[
              "badge",
              if(@service_running, do: "badge-success", else: "badge-error")
            ]}>
              {if @service_running, do: "Running", else: "Stopped"}
            </span>
            <button class="btn btn-sm btn-ghost" phx-click="refresh">
              ↻
            </button>
          </div>
        </div>

        <div class="stats stats-vertical lg:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Total Hosts</div>
            <div class="stat-value">{@stats.total}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Pending</div>
            <div class="stat-value text-warning">{@stats.pending}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Approved</div>
            <div class="stat-value text-success">{@stats.approved}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Revoked</div>
            <div class="stat-value text-error">{@stats.revoked}</div>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title">Trust Level Distribution</h2>
              <div class="space-y-2">
                <div
                  :for={{level, count} <- @stats.trust_levels}
                  class="flex justify-between items-center"
                >
                  <span class="badge badge-outline">{level}</span>
                  <span class="font-mono">{count}</span>
                </div>
                <p :if={@stats.trust_levels == %{}} class="text-base-content/50">
                  No hosts registered
                </p>
              </div>
            </div>
          </div>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title">Trust Providers</h2>
              <div class="space-y-2">
                <div
                  :for={{provider, count} <- @stats.providers}
                  class="flex justify-between items-center"
                >
                  <span class="badge badge-outline">{provider}</span>
                  <span class="font-mono">{count}</span>
                </div>
                <p :if={@stats.providers == %{}} class="text-base-content/50">
                  No hosts registered
                </p>
                <div class="divider my-1"></div>
                <div class="flex justify-between items-center text-sm">
                  <span class="text-base-content/70">Active Tokens</span>
                  <span class="font-mono">{@stats.active_tokens}/{@stats.total_tokens}</span>
                </div>
              </div>
            </div>
          </div>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title">Quick Actions</h2>
              <div class="space-y-2">
                <.link navigate={~p"/identity/hosts"} class="btn btn-sm btn-outline btn-block">
                  View All Hosts
                </.link>
                <.link
                  navigate={~p"/identity/approvals"}
                  class="btn btn-sm btn-warning btn-outline btn-block"
                >
                  Pending Approvals ({@stats.pending})
                </.link>
                <.link navigate={~p"/identity/tokens"} class="btn btn-sm btn-outline btn-block">
                  Provisioning Tokens
                </.link>
                <.link navigate={~p"/identity/policies"} class="btn btn-sm btn-outline btn-block">
                  Approval Policies
                </.link>
                <.link navigate={~p"/identity/audit"} class="btn btn-sm btn-outline btn-block">
                  Audit Log
                </.link>
                <div class="flex gap-1">
                  <button
                    class="btn btn-sm btn-outline flex-1"
                    phx-click="preview_export"
                    phx-value-format="yaml"
                  >
                    Export YAML
                  </button>
                  <button
                    class="btn btn-sm btn-outline flex-1"
                    phx-click="preview_export"
                    phx-value-format="sops"
                  >
                    Export sops
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div :if={@export_preview} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title">
                Export Preview ({String.upcase(@export_format)})
              </h2>
              <button class="btn btn-sm btn-ghost" phx-click="close_export">Close</button>
            </div>
            <pre class="bg-base-200 p-4 rounded-lg text-sm font-mono overflow-x-auto whitespace-pre">{@export_preview}</pre>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
