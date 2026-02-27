defmodule YellowDog.Console.IdentityLive.PoliciesLive do
  @moduledoc "Manages approval policies for automated host enrollment decisions."
  use YellowDog.Console, :live_view

  alias YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Approval Policies") |> load_policies()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_policies(socket)}
  end

  defp load_policies(socket) do
    result =
      ServiceHelper.safe_call(
        YellowDogIdentity,
        fn -> YellowDogIdentity.list_policies() end,
        %{policies: [], default_action: :pending}
      )

    socket
    |> assign(:policies, result.policies)
    |> assign(:default_action, result.default_action)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Approval Policies</h1>
          <button class="btn btn-sm btn-ghost" phx-click="refresh" aria-label="Refresh">
            ↻
          </button>
        </div>

        <div class="alert alert-info">
          <div>
            <p>
              Policies are evaluated in order — first match wins. Configure in
              <code class="font-mono text-sm">config.toml</code>
              under <code class="font-mono text-sm">[identity.approval]</code>.
            </p>
            <p class="mt-1">
              Default action: <span class="badge badge-outline">{@default_action}</span>
            </p>
          </div>
        </div>

        <div :if={@policies == []} class="text-center py-12 text-base-content/50">
          No policies configured. All registrations will use the default action.
        </div>

        <div class="space-y-4">
          <div :for={{policy, idx} <- Enum.with_index(@policies, 1)} class="card bg-base-100 shadow">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-3">
                  <span class="badge badge-neutral badge-lg font-mono">{idx}</span>
                  <div>
                    <h3 class="font-bold text-lg">{policy.name}</h3>
                    <p :if={policy.description} class="text-sm text-base-content/70">
                      {policy.description}
                    </p>
                  </div>
                </div>
                <span class={action_badge_class(policy.action)}>
                  {policy.action}
                </span>
              </div>

              <div :if={policy.match != %{}} class="mt-3">
                <h4 class="text-sm font-semibold text-base-content/70 mb-2">Match Criteria</h4>
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-2">
                  <div
                    :for={{field, value} <- policy.match}
                    class="flex items-center gap-2 text-sm"
                  >
                    <span class="font-mono text-base-content/50">{field}:</span>
                    <span class="font-mono">{format_match_value(value)}</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp action_badge_class(:approve), do: "badge badge-success badge-lg"
  defp action_badge_class(:reject), do: "badge badge-error badge-lg"
  defp action_badge_class(_), do: "badge badge-warning badge-lg"

  defp format_match_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_match_value(value), do: to_string(value)
end
