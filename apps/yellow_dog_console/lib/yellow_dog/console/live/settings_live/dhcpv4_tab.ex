defmodule YellowDog.Console.SettingsLive.Dhcpv4Tab do
  @moduledoc """
  DHCPv4 configuration tab component for the settings interface.

  Provides form inputs for DHCPv4 service configuration including:
  - Service enabled/disabled toggle
  - Listen address (IP)
  - Port number
  - Real-time validation feedback
  - Save and apply change controls

  Note: Address pool management is handled in the dedicated Pools page at /dhcpv4/pools
  """

  use YellowDog.Console, :html

  attr :changeset, Ecto.Changeset, required: true
  attr :pending_changes, :boolean, required: true

  def dhcpv4_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Service Status Header -->
      <.card title="DHCPv4 Service Configuration">
        <:actions>
          <%= if @pending_changes do %>
            <.badge color="warning">Pending Changes</.badge>
          <% else %>
            <.badge color="success">Saved</.badge>
          <% end %>
        </:actions>

        <.form
          for={to_form(@changeset)}
          phx-change="validate_dhcpv4"
          phx-submit="save_dhcpv4"
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
              <span class="font-medium">Enable DHCPv4 Service</span>
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
                Keyword.has_key?(@changeset.errors, :listen) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:listen} />
            <span class="helper-text">IPv4 address to bind DHCPv4 service</span>
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
              placeholder="67"
              class={[
                "input w-full",
                Keyword.has_key?(@changeset.errors, :port) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:port} />
            <span class="helper-text">Default DHCPv4 port is 67 (requires privileges)</span>
          </div>

          <div class="divider"></div>
          <!-- Action Buttons -->
          <div class="flex gap-2 justify-end">
            <%= if @pending_changes do %>
              <button
                type="button"
                phx-click="apply_changes_dhcpv4"
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
      <!-- Address Pools Link -->
      <.card title="Address Pools">
        <div class="flex items-center justify-between">
          <p class="text-on-surface-variant">
            Manage DHCPv4 address pools including IP ranges, lease times, and DNS settings.
          </p>
          <.link navigate="/server/dhcpv4/pools" class="btn btn-primary gap-2">
            <.dm_mdi name="server-network" class="h-5 w-5" /> Manage Pools
          </.link>
        </div>
      </.card>
    </div>
    """
  end
end
