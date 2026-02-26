defmodule YellowDog.Console.IdentityLive.TokensLive do
  @moduledoc "Manages provisioning tokens for host enrollment."
  use YellowDog.Console, :live_view

  alias YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Provisioning Tokens")
     |> assign(:show_create, false)
     |> assign(:new_token_raw, nil)
     |> assign(
       :form,
       to_form(%{"hostname_pattern" => "*", "max_uses" => "1", "ttl_hours" => "24", "role" => ""})
     )
     |> load_tokens()}
  end

  @impl true
  def handle_event("toggle_create", _params, socket) do
    {:noreply, assign(socket, :show_create, !socket.assigns.show_create)}
  end

  @impl true
  def handle_event(
        "create_token",
        %{
          "hostname_pattern" => pattern,
          "max_uses" => max_uses,
          "ttl_hours" => ttl_hours,
          "role" => role
        },
        socket
      ) do
    with {max, _} <- Integer.parse(max_uses),
         {ttl, _} <- Integer.parse(ttl_hours) do
      params = %{
        hostname_pattern: pattern,
        max_uses: max,
        ttl_seconds: ttl * 3600,
        role: if(role == "", do: nil, else: role),
        created_by: "console-operator"
      }

      result =
        ServiceHelper.safe_call(
          YellowDogIdentity,
          fn -> YellowDogIdentity.create_token(params) end,
          {:error, :unavailable}
        )

      case result do
        {:ok, _token, raw_token} ->
          {:noreply,
           socket
           |> assign(:new_token_raw, raw_token)
           |> load_tokens()
           |> put_flash(:info, "Token created successfully")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to create token: #{inspect(reason)}")}
      end
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid number for max uses or TTL")}
    end
  end

  @impl true
  def handle_event("revoke_token", %{"id" => id}, socket) do
    result =
      ServiceHelper.safe_call(
        YellowDogIdentity,
        fn -> YellowDogIdentity.revoke_token(id) end,
        {:error, :unavailable}
      )

    case result do
      :ok -> {:noreply, load_tokens(socket) |> put_flash(:info, "Token revoked")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to revoke token")}
    end
  end

  @impl true
  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token_raw, nil)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_tokens(socket)}
  end

  defp load_tokens(socket) do
    tokens =
      ServiceHelper.safe_call(
        YellowDogIdentity,
        fn ->
          YellowDogIdentity.list_tokens()
        end,
        []
      )

    assign(socket, :tokens, tokens)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Provisioning Tokens</h1>
          <div class="flex gap-2">
            <button class="btn btn-sm btn-primary" phx-click="toggle_create">
              + New Token
            </button>
            <button class="btn btn-sm btn-ghost" phx-click="refresh">
              ↻
            </button>
          </div>
        </div>

        <div :if={@new_token_raw} class="alert alert-success">
          <div>
            <p class="font-bold">Token created! Copy it now — it won't be shown again.</p>
            <code class="block mt-2 p-2 bg-base-300 rounded text-sm break-all">{@new_token_raw}</code>
          </div>
          <button class="btn btn-sm btn-ghost" phx-click="dismiss_token">Dismiss</button>
        </div>

        <div :if={@show_create} class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title">Create Provisioning Token</h2>
            <form phx-submit="create_token" class="space-y-4">
              <div class="form-control">
                <label class="label"><span class="label-text">Hostname Pattern</span></label>
                <input
                  type="text"
                  name="hostname_pattern"
                  value={@form["hostname_pattern"].value}
                  class="input input-bordered"
                  placeholder="node-*"
                />
              </div>
              <div class="grid grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label"><span class="label-text">Max Uses</span></label>
                  <input
                    type="number"
                    name="max_uses"
                    value={@form["max_uses"].value}
                    min="1"
                    class="input input-bordered"
                  />
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text">TTL (hours)</span></label>
                  <input
                    type="number"
                    name="ttl_hours"
                    value={@form["ttl_hours"].value}
                    min="1"
                    class="input input-bordered"
                  />
                </div>
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Role (optional)</span></label>
                <input
                  type="text"
                  name="role"
                  value={@form["role"].value}
                  class="input input-bordered"
                  placeholder="worker"
                />
              </div>
              <button type="submit" class="btn btn-primary" phx-disable-with="Creating...">
                Create Token
              </button>
            </form>
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-zebra w-full">
            <thead>
              <tr>
                <th>ID</th>
                <th>Pattern</th>
                <th>Role</th>
                <th>Uses</th>
                <th>Expires</th>
                <th>Created</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={token <- @tokens} class="hover">
                <td class="font-mono text-xs">{String.slice(token.id, 0, 8)}</td>
                <td class="font-mono">{token.hostname_pattern}</td>
                <td>{token.role || "-"}</td>
                <td>{token.use_count}/{token.max_uses}</td>
                <td>{format_time(token.expires_at)}</td>
                <td class="text-sm">{format_time(token.created_at)}</td>
                <td>
                  <span class={
                    if(YellowDogIdentity.Token.valid?(token),
                      do: "badge badge-success",
                      else: "badge badge-error"
                    )
                  }>
                    {if YellowDogIdentity.Token.valid?(token), do: "Active", else: "Expired"}
                  </span>
                </td>
                <td>
                  <button
                    class="btn btn-xs btn-error btn-outline"
                    phx-click="revoke_token"
                    phx-value-id={token.id}
                    data-confirm="Revoke this provisioning token?"
                  >
                    Revoke
                  </button>
                </td>
              </tr>
              <tr :if={@tokens == []}>
                <td colspan="8" class="text-center text-base-content/50 py-8">
                  No provisioning tokens
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_time(_), do: "-"
end
