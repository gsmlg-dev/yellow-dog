defmodule YellowDog.Console.IdentityLive.HostDetailLive do
  use YellowDog.Console, :live_view

  alias YellowDog.Console.ServiceHelper

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "identity:hosts")
    end

    {:ok, socket |> assign(:host_id, id) |> load_host()}
  end

  @impl true
  def handle_info({:host_updated, host}, socket) do
    if host.id == socket.assigns.host_id do
      {:noreply, assign(socket, :host, host)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("approve", _params, socket) do
    case YellowDogIdentity.approve(socket.assigns.host_id) do
      {:ok, host} -> {:noreply, assign(socket, :host, host)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to approve host")}
    end
  end

  def handle_event("revoke", _params, socket) do
    case YellowDogIdentity.revoke(socket.assigns.host_id, "console-operator") do
      {:ok, host} -> {:noreply, assign(socket, :host, host)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to revoke host")}
    end
  end

  def handle_event("delete", _params, socket) do
    case YellowDogIdentity.delete_host(socket.assigns.host_id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Host deleted")
         |> push_navigate(to: ~p"/identity/hosts")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete host")}
    end
  end

  defp load_host(socket) do
    host_id = socket.assigns.host_id

    host =
      ServiceHelper.safe_call(
        YellowDogIdentity,
        fn ->
          case YellowDogIdentity.get_host(host_id) do
            {:ok, host} -> host
            _ -> nil
          end
        end,
        nil
      )

    audit_entries =
      if host do
        ServiceHelper.safe_call(
          YellowDogIdentity,
          fn -> YellowDogIdentity.audit_log(host_id: host_id, limit: 20) end,
          []
        )
      else
        []
      end

    socket
    |> assign(:host, host)
    |> assign(:audit_entries, audit_entries)
    |> assign(:page_title, if(host, do: "Host: #{host.hostname}", else: "Host Not Found"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center gap-2">
          <.link navigate={~p"/identity/hosts"} class="btn btn-sm btn-ghost">
            ← Back
          </.link>
          <h1 class="text-2xl font-bold">{@page_title}</h1>
        </div>

        <div :if={@host == nil} class="alert alert-error">
          Host not found.
        </div>

        <div :if={@host} class="space-y-6">
          <div class="flex gap-2">
            <button
              :if={@host.status == :pending}
              class="btn btn-sm btn-success"
              phx-click="approve"
              data-confirm="Approve this host?"
            >
              Approve
            </button>
            <button
              :if={@host.status in [:pending, :approved]}
              class="btn btn-sm btn-error"
              phx-click="revoke"
              data-confirm="Revoke this host?"
            >
              Revoke
            </button>
            <button
              :if={@host.status == :revoked}
              class="btn btn-sm btn-error btn-outline"
              phx-click="delete"
              data-confirm="Permanently delete this host? This cannot be undone."
            >
              Delete
            </button>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <div class="card bg-base-100 shadow">
              <div class="card-body">
                <h2 class="card-title">Identity</h2>
                <dl class="space-y-2">
                  <div class="flex justify-between">
                    <dt class="text-base-content/70">ID</dt>
                    <dd class="font-mono text-sm">{@host.id}</dd>
                  </div>
                  <div class="flex justify-between">
                    <dt class="text-base-content/70">Hostname</dt>
                    <dd class="font-bold">{@host.hostname}</dd>
                  </div>
                  <div class="flex justify-between">
                    <dt class="text-base-content/70">Machine ID</dt>
                    <dd class="font-mono text-sm">{@host.machine_id || "-"}</dd>
                  </div>
                  <div class="flex justify-between">
                    <dt class="text-base-content/70">Key Fingerprint</dt>
                    <dd class="font-mono text-xs">{@host.key_fingerprint}</dd>
                  </div>
                  <div class="flex justify-between">
                    <dt class="text-base-content/70">Age Recipient</dt>
                    <dd class="font-mono text-xs max-w-[300px] truncate">{@host.age_recipient}</dd>
                  </div>
                </dl>
              </div>
            </div>

            <div class="card bg-base-100 shadow">
              <div class="card-body">
                <h2 class="card-title">Status & Trust</h2>
                <dl class="space-y-2">
                  <div class="flex justify-between">
                    <dt class="text-base-content/70">Status</dt>
                    <dd>
                      <span class={status_badge_class(@host.status)}>
                        {@host.status}
                      </span>
                    </dd>
                  </div>
                  <div class="flex justify-between">
                    <dt class="text-base-content/70">Trust Level</dt>
                    <dd><span class="badge badge-outline">{@host.trust_level}</span></dd>
                  </div>
                  <div class="flex justify-between">
                    <dt class="text-base-content/70">Trust Provider</dt>
                    <dd>{@host.trust_provider}</dd>
                  </div>
                  <div class="flex justify-between">
                    <dt class="text-base-content/70">Role</dt>
                    <dd>{@host.role || "-"}</dd>
                  </div>
                  <div class="flex justify-between">
                    <dt class="text-base-content/70">Datacenter</dt>
                    <dd>{@host.datacenter || "-"}</dd>
                  </div>
                </dl>
              </div>
            </div>
          </div>

          <div :if={@host.trust_evidence != %{}} class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title">Trust Evidence</h2>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <tbody>
                    <tr :for={{key, value} <- @host.trust_evidence}>
                      <td class="font-mono text-sm text-base-content/70">{key}</td>
                      <td class="font-mono text-sm">{format_evidence_value(value)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <div :if={@host.previous_keys != []} class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title">Previous Keys</h2>
              <div :for={pk <- @host.previous_keys} class="p-2 bg-base-200 rounded mb-2">
                <p class="font-mono text-xs">Fingerprint: {Map.get(pk, "key_fingerprint", "-")}</p>
                <p class="text-xs text-base-content/50">
                  Replaced: {Map.get(pk, "replaced_at", "-")}
                </p>
              </div>
            </div>
          </div>

          <div :if={@audit_entries != []} class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title">Audit Trail</h2>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Time</th>
                      <th>Event</th>
                      <th>Details</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @audit_entries}>
                      <td class="font-mono text-xs whitespace-nowrap">{entry.timestamp}</td>
                      <td><span class={audit_badge(entry.event)}>{entry.event}</span></td>
                      <td class="font-mono text-xs">{entry.details}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title">Timeline</h2>
              <dl class="space-y-1">
                <div class="flex justify-between">
                  <dt class="text-base-content/70">Created</dt>
                  <dd>{format_time(@host.created_at)}</dd>
                </div>
                <div :if={@host.approved_at} class="flex justify-between">
                  <dt class="text-base-content/70">Approved</dt>
                  <dd>{format_time(@host.approved_at)} by {@host.approved_by}</dd>
                </div>
                <div :if={@host.revoked_at} class="flex justify-between">
                  <dt class="text-base-content/70">Revoked</dt>
                  <dd>{format_time(@host.revoked_at)} by {@host.revoked_by}</dd>
                </div>
                <div :if={@host.revoke_reason} class="flex justify-between">
                  <dt class="text-base-content/70">Reason</dt>
                  <dd>{@host.revoke_reason}</dd>
                </div>
              </dl>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp audit_badge("host.registered"), do: "badge badge-info badge-sm"
  defp audit_badge("host.approved"), do: "badge badge-success badge-sm"
  defp audit_badge("host.revoked"), do: "badge badge-error badge-sm"
  defp audit_badge("host.key_rotated"), do: "badge badge-warning badge-sm"
  defp audit_badge("host.deleted"), do: "badge badge-error badge-outline badge-sm"
  defp audit_badge(_), do: "badge badge-sm"

  defp status_badge_class(:pending), do: "badge badge-warning"
  defp status_badge_class(:approved), do: "badge badge-success"
  defp status_badge_class(:revoked), do: "badge badge-error"
  defp status_badge_class(_), do: "badge"

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_time(_), do: "-"

  defp format_evidence_value(value) when is_tuple(value) and tuple_size(value) == 4 do
    # IPv4 tuple
    :inet.ntoa(value) |> to_string()
  rescue
    _ -> inspect(value)
  end

  defp format_evidence_value(value) when is_tuple(value) and tuple_size(value) == 8 do
    # IPv6 tuple
    :inet.ntoa(value) |> to_string()
  rescue
    _ -> inspect(value)
  end

  defp format_evidence_value(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_evidence_value(value) when is_atom(value), do: to_string(value)
  defp format_evidence_value(value) when is_binary(value), do: value
  defp format_evidence_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_evidence_value(value) when is_number(value), do: to_string(value)
  defp format_evidence_value(value), do: inspect(value)
end
