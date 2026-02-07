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
          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-4">
              <input type="hidden" name="service_configuration[enabled]" value="false" />
              <input
                type="checkbox"
                name="service_configuration[enabled]"
                value="true"
                class="toggle toggle-success"
                checked={Ecto.Changeset.get_field(@changeset, :enabled)}
              />
              <span class="label-text font-medium">Enable DNS Service</span>
            </label>
            <.input_error changeset={@changeset} field={:enabled} />
          </div>
          
    <!-- Listen Address -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Listen Address</span>
            </label>
            <input
              type="text"
              name="service_configuration[listen]"
              value={Ecto.Changeset.get_field(@changeset, :listen)}
              placeholder="0.0.0.0"
              class={[
                "input input-bordered w-full",
                has_error?(@changeset, :listen) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:listen} />
            <label class="label">
              <span class="label-text-alt">
                IP address to bind DNS service (0.0.0.0 for all interfaces)
              </span>
            </label>
          </div>
          
    <!-- Port -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Port</span>
            </label>
            <input
              type="number"
              name="service_configuration[port]"
              value={Ecto.Changeset.get_field(@changeset, :port)}
              placeholder="53"
              min="1"
              max="65535"
              class={[
                "input input-bordered w-full",
                has_error?(@changeset, :port) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:port} />
            <label class="label">
              <span class="label-text-alt">UDP port for DNS queries (default: 53)</span>
            </label>
          </div>
          
    <!-- Configuration Info -->
          <div class="alert alert-info">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="stroke-current shrink-0 w-6 h-6"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              >
              </path>
            </svg>
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
                !@changeset.valid? && "btn-disabled"
              ]}
              disabled={!@changeset.valid?}
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5 mr-2"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M8 7H5a2 2 0 00-2 2v9a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-3m-1 4l-3 3m0 0l-3-3m3 3V4"
                />
              </svg>
              Save Configuration
            </button>

            <%= if Map.has_key?(@pending_changes, :dns) do %>
              <button
                type="button"
                phx-click="apply_changes_dns"
                class="btn btn-success"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5 mr-2"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                  />
                </svg>
                Apply Changes & Restart Service
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
          <p class="text-sm text-base-content/70">
            Reload DNS subsystem components from their persisted configuration without restarting the entire service.
          </p>

          <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
            <!-- Reload All -->
            <button
              type="button"
              phx-click="dns_reload_all"
              class="btn btn-outline btn-sm gap-2"
            >
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                />
              </svg>
              Reload All
            </button>
            <!-- Reload Views -->
            <button
              type="button"
              phx-click="dns_reload_views"
              class="btn btn-outline btn-sm gap-2"
            >
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                />
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
                />
              </svg>
              Reload Views
            </button>
            <!-- Reload ACLs -->
            <button
              type="button"
              phx-click="dns_reload_acls"
              class="btn btn-outline btn-sm gap-2"
            >
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
                />
              </svg>
              Reload ACLs
            </button>
          </div>

          <div class="text-xs text-base-content/50">
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

  attr :changeset, Ecto.Changeset, required: true
  attr :field, :atom, required: true

  defp input_error(assigns) do
    assigns =
      assign(assigns, :errors, Keyword.get_values(assigns.changeset.errors, assigns.field))

    ~H"""
    <%= if @errors != [] do %>
      <div class="label">
        <span class="label-text-alt text-error">
          {translate_error(Enum.at(@errors, 0))}
        </span>
      </div>
    <% end %>
    """
  end
end
