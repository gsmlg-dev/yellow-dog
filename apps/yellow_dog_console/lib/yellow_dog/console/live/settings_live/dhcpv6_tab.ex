defmodule YellowDog.Console.SettingsLive.Dhcpv6Tab do
  @moduledoc """
  DHCPv6 configuration tab component for the settings interface.

  Provides form inputs for DHCPv6 service configuration including:
  - Service enabled/disabled toggle
  - Listen address (IPv6)
  - Port number
  - Real-time validation feedback
  - Save and apply change controls

  Note: Address pool management is handled in the dedicated Pools page at /dhcpv6/pools
  """

  use YellowDog.Console, :html

  attr :changeset, Ecto.Changeset, required: true
  attr :pending_changes, :boolean, required: true

  def dhcpv6_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Service Status Header -->
      <.card title="DHCPv6 Service Configuration">
        <:actions>
          <%= if @pending_changes do %>
            <.badge color="warning">Pending Changes</.badge>
          <% else %>
            <.badge color="success">Saved</.badge>
          <% end %>
        </:actions>

        <.form
          for={to_form(@changeset)}
          phx-change="validate_dhcpv6"
          phx-submit="save_dhcpv6"
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
              <span class="font-medium">Enable DHCPv6 Service</span>
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
              placeholder="::"
              class={[
                "input w-full",
                Keyword.has_key?(@changeset.errors, :listen) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:listen} />
            <span class="helper-text">IPv6 address to bind DHCPv6 service</span>
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
              placeholder="547"
              class={[
                "input w-full",
                Keyword.has_key?(@changeset.errors, :port) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:port} />
            <span class="helper-text">Default DHCPv6 port is 547 (requires privileges)</span>
          </div>

          <div class="divider"></div>
          <!-- Action Buttons -->
          <div class="flex gap-2 justify-end">
            <%= if @pending_changes do %>
              <button
                type="button"
                phx-click="apply_changes_dhcpv6"
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
            Manage DHCPv6 address pools including IPv6 ranges, lifetimes, and DNS settings.
          </p>
          <.link navigate="/server/dhcpv6/pools" class="btn btn-primary gap-2">
            <.dm_mdi name="server-network" class="h-5 w-5" /> Manage Pools
          </.link>
        </div>
      </.card>
    </div>
    """
  end
end
