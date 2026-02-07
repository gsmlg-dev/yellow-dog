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
              <span class="label-text font-medium">Enable mDNS Service</span>
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
              placeholder="0.0.0.0 or ::"
              class={[
                "input input-bordered w-full",
                !Enum.empty?(Keyword.get_values(@changeset.errors, :listen)) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:listen} />
            <label class="label">
              <span class="label-text-alt">IPv4 or IPv6 address to bind mDNS service</span>
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
              placeholder="5353"
              class={[
                "input input-bordered w-full",
                !Enum.empty?(Keyword.get_values(@changeset.errors, :port)) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:port} />
            <label class="label">
              <span class="label-text-alt">Default mDNS port is 5353</span>
            </label>
          </div>
          
    <!-- Mode Selection -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Mode</span>
            </label>
            <select
              name="service_configuration[mode]"
              aria-label="mDNS mode"
              class={[
                "select select-bordered w-full",
                !Enum.empty?(Keyword.get_values(@changeset.errors, :mode)) && "select-error"
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
            <label class="label">
              <span class="label-text-alt">
                Responder: Answer queries only. Hybrid: Answer and query other services
              </span>
            </label>
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
    </div>
    """
  end

end
