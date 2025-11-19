defmodule YellowDog.Console.SettingsLive.Dhcpv6Tab do
  @moduledoc """
  DHCPv6 configuration tab component for the settings interface.

  Provides form inputs for DHCPv6 service configuration including:
  - Service enabled/disabled toggle
  - Listen address (IPv6)
  - Port number
  - Address pool management (CRUD operations)
  - Real-time validation feedback
  - Save and apply change controls
  """

  use YellowDog.Console, :html

  attr :changeset, Ecto.Changeset, required: true
  attr :pending_changes, :boolean, required: true

  def dhcpv6_tab(assigns) do
    pools = Ecto.Changeset.get_field(assigns.changeset, :pools) || []
    assigns = assign(assigns, :pools, pools)

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
      
    <!-- Address Pools Section -->
      <.card title="Address Pools">
        <:actions>
          <button phx-click="add_dhcpv6_pool" class="btn btn-primary btn-sm gap-2">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 4v16m8-8H4"
              />
            </svg>
            Add Pool
          </button>
        </:actions>

        <%= if Enum.empty?(@pools) do %>
          <div class="text-center py-8">
            <p class="text-gray-500">No address pools configured. Click "Add Pool" to create one.</p>
          </div>
        <% else %>
          <.pool_table pools={@pools} />
        <% end %>
      </.card>
    </div>
    """
  end

  attr :pools, :list, required: true

  defp pool_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-zebra w-full">
        <thead>
          <tr>
            <th>Name</th>
            <th>IPv6 Range</th>
            <th>Preferred Lifetime</th>
            <th>Valid Lifetime</th>
            <th>DNS Servers</th>
            <th class="text-right">Actions</th>
          </tr>
        </thead>
        <tbody>
          <%= for pool <- @pools do %>
            <tr>
              <td class="font-medium">{pool.name}</td>
              <td>{pool.range_start} - {pool.range_end}</td>
              <td>{format_lifetime(pool.preferred_lifetime)}</td>
              <td>{format_lifetime(pool.valid_lifetime)}</td>
              <td>{format_dns_servers(pool.dns_servers)}</td>
              <td class="text-right">
                <div class="flex gap-2 justify-end">
                  <button
                    phx-click="edit_dhcpv6_pool"
                    phx-value-pool-id={pool.id}
                    class="btn btn-ghost btn-sm"
                  >
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      class="h-4 w-4"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
                      />
                    </svg>
                  </button>
                  <button
                    phx-click="delete_dhcpv6_pool"
                    phx-value-pool-id={pool.id}
                    class="btn btn-ghost btn-sm text-error"
                    data-confirm="Delete this pool?"
                  >
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      class="h-4 w-4"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                      />
                    </svg>
                  </button>
                </div>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp format_lifetime(nil), do: "-"
  defp format_lifetime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_lifetime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_lifetime(seconds), do: "#{div(seconds, 3600)}h"

  defp format_dns_servers([]), do: "-"
  defp format_dns_servers(servers), do: Enum.join(servers, ", ")

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
