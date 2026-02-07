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
              <span class="label-text font-medium">Enable DHCPv6 Service</span>
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
              placeholder="::"
              class={[
                "input input-bordered w-full",
                !Enum.empty?(Keyword.get_values(@changeset.errors, :listen)) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:listen} />
            <label class="label">
              <span class="label-text-alt">IPv6 address to bind DHCPv6 service</span>
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
              min="1"
              max="65535"
              placeholder="547"
              class={[
                "input input-bordered w-full",
                !Enum.empty?(Keyword.get_values(@changeset.errors, :port)) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:port} />
            <label class="label">
              <span class="label-text-alt">Default DHCPv6 port is 547 (requires privileges)</span>
            </label>
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
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5"
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
                Apply Changes
              </button>
            <% end %>

            <button
              type="submit"
              phx-disable-with="Saving..."
              class={[
                "btn btn-primary gap-2",
                !@changeset.valid? && "btn-disabled"
              ]}
              disabled={!@changeset.valid?}
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
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
          </div>
        </.form>
      </.card>
      
    <!-- Address Pools Link -->
      <.card title="Address Pools">
        <div class="flex items-center justify-between">
          <p class="text-base-content/70">
            Manage DHCPv6 address pools including IPv6 ranges, lifetimes, and DNS settings.
          </p>
          <.link navigate="/dhcpv6/pools" class="btn btn-primary gap-2">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"
              />
            </svg>
            Manage Pools
          </.link>
        </div>
      </.card>
    </div>
    """
  end
end
