defmodule YellowDog.Console.SettingsLive.NetbootTab do
  @moduledoc """
  Netboot configuration tab component for the settings interface.

  Provides form inputs for netboot service configuration including:
  - Service enabled/disabled toggle
  - TFTP root directory
  - TFTP port number
  - Default boot profile
  - Real-time validation feedback
  - Save and apply change controls
  """

  use YellowDog.Console, :html

  attr :changeset, Ecto.Changeset, required: true
  attr :pending_changes, :boolean, required: true
  attr :profiles, :list, default: []

  def netboot_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <.card title="Netboot Service Configuration">
        <:actions>
          <%= if @pending_changes do %>
            <.badge color="warning">Pending Changes</.badge>
          <% else %>
            <.badge color="success">Saved</.badge>
          <% end %>
        </:actions>

        <.form
          for={to_form(@changeset)}
          phx-change="validate_netboot"
          phx-submit="save_netboot"
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
              <span class="label-text font-medium">Enable Netboot Service</span>
            </label>
            <.input_error changeset={@changeset} field={:enabled} />
          </div>

          <!-- TFTP Root Directory -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">TFTP Root Directory</span>
            </label>
            <input
              type="text"
              name="service_configuration[tftp_root]"
              value={Ecto.Changeset.get_field(@changeset, :tftp_root)}
              placeholder="/srv/netboot/tftp"
              class={[
                "input input-bordered w-full font-mono",
                Keyword.has_key?(@changeset.errors, :tftp_root) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:tftp_root} />
            <label class="label">
              <span class="label-text-alt">
                Directory containing boot assets (kernels, initrds, iPXE binaries)
              </span>
            </label>
          </div>

          <!-- TFTP Port -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">TFTP Port</span>
            </label>
            <input
              type="number"
              name="service_configuration[port]"
              value={Ecto.Changeset.get_field(@changeset, :port)}
              min="1"
              max="65535"
              placeholder="69"
              class={[
                "input input-bordered w-full",
                Keyword.has_key?(@changeset.errors, :port) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:port} />
            <label class="label">
              <span class="label-text-alt">Default TFTP port is 69 (requires root or capabilities)</span>
            </label>
          </div>

          <!-- Default Profile -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Default Boot Profile</span>
            </label>
            <select
              name="service_configuration[default_profile]"
              aria-label="Default boot profile"
              class="select select-bordered w-full"
            >
              <option value="" selected={is_nil(Ecto.Changeset.get_field(@changeset, :default_profile)) or Ecto.Changeset.get_field(@changeset, :default_profile) == ""}>
                None
              </option>
              <%= for profile <- @profiles do %>
                <option
                  value={profile.id}
                  selected={Ecto.Changeset.get_field(@changeset, :default_profile) == profile.id}
                >
                  {profile.id}
                  <%= if profile.description do %>
                    — {profile.description}
                  <% end %>
                </option>
              <% end %>
            </select>
            <.input_error changeset={@changeset} field={:default_profile} />
            <label class="label">
              <span class="label-text-alt">
                Profile assigned to newly discovered devices
              </span>
            </label>
          </div>

          <div class="divider"></div>

          <!-- Action Buttons -->
          <div class="flex gap-2 justify-end">
            <%= if @pending_changes do %>
              <button
                type="button"
                phx-click="apply_changes_netboot"
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
