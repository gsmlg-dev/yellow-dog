defmodule YellowDog.Console.SettingsLive.DnsTab do
  @moduledoc """
  DNS configuration tab component for the settings interface.

  Provides form inputs for DNS service configuration including:
  - Service enabled/disabled toggle
  - Listen address (IP)
  - Port number
  - Real-time validation feedback
  - Save and apply change controls
  """

  use YellowDog.Console, :html

  attr :changeset, Ecto.Changeset, required: true
  attr :pending_changes, :map, default: %{}

  def dns_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Service Status Header -->
      <.card title="DNS Service Configuration">
        <:actions>
          <%= if Map.has_key?(@pending_changes, :dns) do %>
            <.badge color="warning">Pending Changes</.badge>
          <% else %>
            <.badge color="success">Saved</.badge>
          <% end %>
        </:actions>

        <.form
          for={to_form(@changeset)}
          phx-change="validate_dns"
          phx-submit="save_dns"
          class="space-y-4"
        >
          <!-- Enabled Toggle -->
          <div class="form-group">
            <label class="label cursor-pointer justify-start gap-4">
              <input type="hidden" name="service_configuration[enabled]" value="false" />
              <input
                type="checkbox"
                name="service_configuration[enabled]"
                value="true"
                class="switch switch-primary"
                checked={Ecto.Changeset.get_field(@changeset, :enabled)}
              />
              <span class="font-medium">Enable DNS Service</span>
            </label>
            <.input_error changeset={@changeset} field={:enabled} />
          </div>
          <!-- Listen Address -->
          <div class="form-group">
            <label class="form-label">Listen Address</label>
            <input
              type="text"
              name="service_configuration[listen]"
              value={Ecto.Changeset.get_field(@changeset, :listen)}
              placeholder="0.0.0.0"
              class={[
                "input w-full",
                has_error?(@changeset, :listen) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:listen} />
            <span class="helper-text">
              IP address to bind DNS service (0.0.0.0 for all interfaces)
            </span>
          </div>
          <!-- Port -->
          <div class="form-group">
            <label class="form-label">Port</label>
            <input
              type="number"
              name="service_configuration[port]"
              value={Ecto.Changeset.get_field(@changeset, :port)}
              placeholder="53"
              min="1"
              max="65535"
              class={[
                "input w-full",
                has_error?(@changeset, :port) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:port} />
            <span class="helper-text">UDP port for DNS queries (default: 53)</span>
          </div>
          <!-- Configuration Info -->
          <div class="alert alert-info">
            <.dm_mdi name="information" class="shrink-0 w-6 h-6" />
            <div class="text-sm">
              <p class="font-medium">DNS Configuration Notes:</p>
              <ul class="list-disc list-inside mt-1 space-y-1">
                <li>Port 53 is the standard DNS port (requires privileged access)</li>
                <li>Changes require service restart to take effect</li>
                <li>Use "Save" to persist configuration, then "Apply Changes" to restart service</li>
              </ul>
            </div>
          </div>
          <!-- Action Buttons -->
          <div class="flex gap-3 pt-4">
            <button
              type="submit"
              phx-disable-with="Saving..."
              class={[
                "btn btn-primary",
                false
              ]}
              disabled={!@changeset.valid?}
            >
              <.dm_mdi name="content-save" class="h-5 w-5 mr-2" /> Save Configuration
            </button>

            <%= if Map.has_key?(@pending_changes, :dns) do %>
              <button
                type="button"
                phx-click="apply_changes_dns"
                phx-disable-with="Applying..."
                class="btn btn-success"
              >
                <.dm_mdi name="refresh" class="h-5 w-5 mr-2" /> Apply Changes & Restart Service
              </button>
            <% end %>
          </div>
        </.form>
      </.card>
      <!-- DNS Runtime Operations -->
      <.card title="DNS Runtime Operations">
        <:actions>
          <.badge color="info" size="sm">Live</.badge>
        </:actions>

        <div class="space-y-4">
          <p class="text-sm text-on-surface-variant">
            Reload DNS subsystem components from their persisted configuration without restarting the entire service.
          </p>

          <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
            <!-- Reload All -->
            <button
              type="button"
              phx-click="dns_reload_all"
              phx-disable-with="Reloading..."
              class="btn btn-outline btn-sm gap-2"
            >
              <.dm_mdi name="refresh" class="w-4 h-4" /> Reload All
            </button>
            <!-- Reload Views -->
            <button
              type="button"
              phx-click="dns_reload_views"
              phx-disable-with="Reloading..."
              class="btn btn-outline btn-sm gap-2"
            >
              <.dm_mdi name="eye" class="w-4 h-4" /> Reload Views
            </button>
            <!-- Reload ACLs -->
            <button
              type="button"
              phx-click="dns_reload_acls"
              phx-disable-with="Reloading..."
              class="btn btn-outline btn-sm gap-2"
            >
              <.dm_mdi name="lock" class="w-4 h-4" /> Reload ACLs
            </button>
          </div>

          <div class="text-xs text-on-surface-variant">
            Hot-reload applies configuration changes to running processes without dropping active connections.
          </div>
        </div>
      </.card>
    </div>
    """
  end

  defp has_error?(changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end
end
