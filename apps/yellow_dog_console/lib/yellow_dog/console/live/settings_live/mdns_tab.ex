defmodule YellowDog.Console.SettingsLive.MdnsTab do
  @moduledoc """
  mDNS configuration tab component for the settings interface.

  Provides form inputs for mDNS service configuration including:
  - Service enabled/disabled toggle
  - Listen address (IP)
  - Port number
  - Mode selection (responder/hybrid)
  - Real-time validation feedback
  - Save and apply change controls
  """

  use YellowDog.Console, :html

  attr :changeset, Ecto.Changeset, required: true
  attr :pending_changes, :boolean, required: true

  def mdns_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Service Status Header -->
      <.card title="mDNS Service Configuration">
        <:actions>
          <%= if @pending_changes do %>
            <.badge color="warning">Pending Changes</.badge>
          <% else %>
            <.badge color="success">Saved</.badge>
          <% end %>
        </:actions>

        <.form
          for={to_form(@changeset)}
          phx-change="validate_mdns"
          phx-submit="save_mdns"
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
              <span class="font-medium">Enable mDNS Service</span>
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
              placeholder="0.0.0.0 or ::"
              class={[
                "input w-full",
                Keyword.has_key?(@changeset.errors, :listen) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:listen} />
            <span class="helper-text">IPv4 or IPv6 address to bind mDNS service</span>
          </div>
          <!-- Port -->
          <div class="form-group">
            <label class="form-label">Port</label>
            <input
              type="number"
              name="service_configuration[port]"
              value={Ecto.Changeset.get_field(@changeset, :port)}
              min="1"
              max="65535"
              placeholder="5353"
              class={[
                "input w-full",
                Keyword.has_key?(@changeset.errors, :port) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:port} />
            <span class="helper-text">Default mDNS port is 5353</span>
          </div>
          <!-- Mode Selection -->
          <div class="form-group">
            <label class="form-label">Mode</label>
            <select
              name="service_configuration[mode]"
              aria-label="mDNS mode"
              class={[
                "select w-full",
                Keyword.has_key?(@changeset.errors, :mode) && "select-error"
              ]}
            >
              <option value="" disabled selected={is_nil(Ecto.Changeset.get_field(@changeset, :mode))}>
                Select mode
              </option>
              <option
                value="responder"
                selected={Ecto.Changeset.get_field(@changeset, :mode) == :responder}
              >
                Responder
              </option>
              <option value="hybrid" selected={Ecto.Changeset.get_field(@changeset, :mode) == :hybrid}>
                Hybrid
              </option>
            </select>
            <.input_error changeset={@changeset} field={:mode} />
            <span class="helper-text">
              Responder: Answer queries only. Hybrid: Answer and query other services
            </span>
          </div>

          <div class="divider"></div>
          <!-- Action Buttons -->
          <div class="flex gap-2 justify-end">
            <%= if @pending_changes do %>
              <button
                type="button"
                phx-click="apply_changes_mdns"
                phx-disable-with="Applying..."
                class="btn btn-success gap-2"
              >
                <.dm_mdi name="refresh" class="h-5 w-5" /> Apply Changes
              </button>
            <% end %>

            <button
              type="submit"
              phx-disable-with="Saving..."
              class={[
                "btn btn-primary gap-2",
                false
              ]}
              disabled={!@changeset.valid?}
            >
              <.dm_mdi name="content-save" class="h-5 w-5" /> Save Configuration
            </button>
          </div>
        </.form>
      </.card>
    </div>
    """
  end
end
