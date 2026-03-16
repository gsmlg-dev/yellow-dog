defmodule YellowDog.Console.BackupsLive do
  @moduledoc """
  LiveView for backup and restore operations.

  Provides UI for creating, verifying, restoring, and deleting
  Concord data backups via `YellowDog.Store.Backup`.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Store.Backup

  @default_backup_dir "./backups"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Backups",
       backups: [],
       creating: false,
       restoring: false,
       verifying: nil,
       verify_result: nil,
       confirm_restore: nil,
       label: ""
     )
     |> load_backups()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl">
        <div class="flex justify-between items-center mb-6">
          <div>
            <h1 class="text-3xl font-bold">Backups</h1>
            <p class="text-sm text-on-surface-variant mt-1">
              Create, verify, and restore Concord data backups
            </p>
          </div>
          <button phx-click="refresh" class="btn btn-ghost btn-sm">
            <.dm_mdi name="refresh" class="h-5 w-5" /> Refresh
          </button>
        </div>

        <div class="card bg-surface shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-lg">Create Backup</h2>
            <p class="text-sm text-on-surface-variant">
              Snapshot all Concord data (leases, zones, config, devices, RPZ rules).
            </p>
            <div class="flex items-end gap-4 mt-4">
              <div class="form-control flex-1">
                <label class="label">
                  <span class="label-text">Label (optional)</span>
                </label>
                <input
                  type="text"
                  value={@label}
                  phx-change="update_label"
                  name="label"
                  class="input input-bordered w-full"
                  placeholder="e.g. nightly, pre-migration"
                />
              </div>
              <button
                phx-click="create_backup"
                class="btn btn-primary"
                disabled={@creating}
              >
                <%= if @creating do %>
                  <span class="loading loading-spinner loading-sm"></span> Creating...
                <% else %>
                  <.dm_mdi name="plus" class="h-5 w-5" /> Create Backup
                <% end %>
              </button>
            </div>
          </div>
        </div>

        <%= if @verify_result do %>
          <div class={[
            "alert mb-6",
            if(@verify_result.valid, do: "alert-success", else: "alert-error")
          ]}>
            <.dm_mdi
              name={if(@verify_result.valid, do: "check-circle", else: "alert-circle")}
              class="h-5 w-5"
            />
            <span>
              <%= if @verify_result.valid do %>
                Backup verified: integrity check passed.
              <% else %>
                Backup verification failed: integrity check did not pass.
              <% end %>
            </span>
            <button phx-click="dismiss_verify" class="btn btn-ghost btn-sm">Dismiss</button>
          </div>
        <% end %>

        <%= if @confirm_restore do %>
          <.modal id="restore-modal" title="Confirm Restore" show={true}>
            <div class="space-y-4">
              <div class="alert alert-warning">
                <.dm_mdi name="alert" class="h-5 w-5" />
                <span>
                  Restoring will <strong>overwrite all current Concord data</strong>.
                  This operation cannot be undone.
                </span>
              </div>
              <p class="text-sm text-on-surface-variant">
                File: <code class="text-xs"><%= Path.basename(@confirm_restore) %></code>
              </p>
              <div class="flex justify-end gap-2 mt-4">
                <button phx-click="cancel_restore" class="btn btn-ghost">Cancel</button>
                <button
                  phx-click="do_restore"
                  class="btn btn-error"
                  disabled={@restoring}
                >
                  <%= if @restoring do %>
                    <span class="loading loading-spinner loading-sm"></span> Restoring...
                  <% else %>
                    <.dm_mdi name="backup-restore" class="h-5 w-5" /> Restore
                  <% end %>
                </button>
              </div>
            </div>
          </.modal>
        <% end %>

        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title text-lg">Available Backups</h2>
            <%= if @backups == [] do %>
              <p class="text-on-surface-variant py-8 text-center">
                No backups found. Create one above.
              </p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-zebra w-full">
                  <thead>
                    <tr>
                      <th>File</th>
                      <th>Timestamp</th>
                      <th>Size</th>
                      <th>Entries</th>
                      <th class="text-right">Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for backup <- @backups do %>
                      <tr>
                        <td class="font-mono text-xs">
                          <%= Path.basename(backup.path) %>
                        </td>
                        <td><%= format_timestamp(backup[:timestamp]) %></td>
                        <td><%= format_bytes(backup[:size_bytes]) %></td>
                        <td><%= backup[:entry_count] || "—" %></td>
                        <td class="text-right">
                          <div class="flex justify-end gap-1">
                            <button
                              phx-click="verify"
                              phx-value-path={backup.path}
                              class="btn btn-ghost btn-xs"
                              disabled={@verifying == backup.path}
                            >
                              <%= if @verifying == backup.path do %>
                                <span class="loading loading-spinner loading-xs"></span>
                              <% else %>
                                <.dm_mdi name="shield-check" class="h-4 w-4" />
                              <% end %>
                              Verify
                            </button>
                            <button
                              phx-click="restore"
                              phx-value-path={backup.path}
                              class="btn btn-warning btn-xs"
                            >
                              <.dm_mdi name="backup-restore" class="h-4 w-4" /> Restore
                            </button>
                            <button
                              phx-click="delete"
                              phx-value-path={backup.path}
                              class="btn btn-ghost btn-xs text-error"
                              data-confirm="Delete this backup? This cannot be undone."
                            >
                              <.dm_mdi name="delete" class="h-4 w-4" />
                            </button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("update_label", %{"label" => label}, socket) do
    {:noreply, assign(socket, :label, label)}
  end

  def handle_event("create_backup", _params, socket) do
    label = socket.assigns.label
    opts = if label != "", do: [label: label], else: []

    socket =
      socket
      |> assign(:creating, true)
      |> start_async(:create_backup, fn -> Backup.create(opts) end)

    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_backups(socket)}
  end

  def handle_event("verify", %{"path" => path}, socket) do
    socket =
      socket
      |> assign(:verifying, path)
      |> assign(:verify_result, nil)
      |> start_async(:verify_backup, fn -> Backup.verify(path) end)

    {:noreply, socket}
  end

  def handle_event("dismiss_verify", _params, socket) do
    {:noreply, assign(socket, :verify_result, nil)}
  end

  def handle_event("restore", %{"path" => path}, socket) do
    {:noreply, assign(socket, :confirm_restore, path)}
  end

  def handle_event("cancel_restore", _params, socket) do
    {:noreply, assign(socket, confirm_restore: nil, restoring: false)}
  end

  def handle_event("do_restore", _params, socket) do
    path = socket.assigns.confirm_restore

    socket =
      socket
      |> assign(:restoring, true)
      |> start_async(:restore_backup, fn -> Backup.restore(path, confirm: true) end)

    {:noreply, socket}
  end

  def handle_event("delete", %{"path" => path}, socket) do
    case Backup.delete(path) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Backup deleted.")
         |> load_backups()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  # --- Async Handlers ---

  @impl true
  def handle_async(:create_backup, {:ok, {:ok, path}}, socket) do
    {:noreply,
     socket
     |> assign(creating: false, label: "")
     |> put_flash(:info, "Backup created: #{Path.basename(path)}")
     |> load_backups()}
  end

  def handle_async(:create_backup, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:creating, false)
     |> put_flash(:error, "Backup failed: #{inspect(reason)}")}
  end

  def handle_async(:create_backup, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:creating, false)
     |> put_flash(:error, "Backup failed: #{inspect(reason)}")}
  end

  def handle_async(:verify_backup, {:ok, {:ok, result}}, socket) do
    {:noreply, assign(socket, verifying: nil, verify_result: result)}
  end

  def handle_async(:verify_backup, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:verifying, nil)
     |> put_flash(:error, "Verify failed: #{inspect(reason)}")}
  end

  def handle_async(:verify_backup, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:verifying, nil)
     |> put_flash(:error, "Verify failed: #{inspect(reason)}")}
  end

  def handle_async(:restore_backup, {:ok, {:ok, _stats}}, socket) do
    {:noreply,
     socket
     |> assign(restoring: false, confirm_restore: nil)
     |> put_flash(:info, "Restore completed successfully.")}
  end

  def handle_async(:restore_backup, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(restoring: false, confirm_restore: nil)
     |> put_flash(:error, "Restore failed: #{inspect(reason)}")}
  end

  def handle_async(:restore_backup, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(restoring: false, confirm_restore: nil)
     |> put_flash(:error, "Restore failed: #{inspect(reason)}")}
  end

  # --- Helpers ---

  defp load_backups(socket) do
    backups =
      case Backup.list(dir: @default_backup_dir) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    assign(socket, :backups, backups)
  end

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(ts) when is_integer(ts) do
    ts
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_timestamp(_), do: "—"

  defp format_bytes(nil), do: "—"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"
end
