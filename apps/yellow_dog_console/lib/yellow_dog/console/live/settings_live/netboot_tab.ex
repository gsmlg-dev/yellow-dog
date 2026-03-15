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
              <span class="font-medium">Enable Netboot Service</span>
            </label>
            <.input_error changeset={@changeset} field={:enabled} />
          </div>
          <!-- TFTP Root Directory -->
          <div class="form-group">
            <label class="form-label">TFTP Root Directory</label>
            <input
              type="text"
              name="service_configuration[tftp_root]"
              value={Ecto.Changeset.get_field(@changeset, :tftp_root)}
              placeholder="/srv/netboot/tftp"
              class={[
                "input w-full font-mono",
                Keyword.has_key?(@changeset.errors, :tftp_root) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:tftp_root} />
            <span class="helper-text">
              Directory containing boot assets (kernels, initrds, iPXE binaries)
            </span>
          </div>
          <!-- TFTP Port -->
          <div class="form-group">
            <label class="form-label">TFTP Port</label>
            <input
              type="number"
              name="service_configuration[port]"
              value={Ecto.Changeset.get_field(@changeset, :port)}
              min="1"
              max="65535"
              placeholder="69"
              class={[
                "input w-full",
                Keyword.has_key?(@changeset.errors, :port) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:port} />
            <span class="helper-text">
              Default TFTP port is 69 (requires root or capabilities)
            </span>
          </div>
          <!-- Default Profile -->
          <div class="form-group">
            <label class="form-label">Default Boot Profile</label>
            <select
              name="service_configuration[default_profile]"
              aria-label="Default boot profile"
              class="select w-full"
            >
              <option
                value=""
                selected={
                  is_nil(Ecto.Changeset.get_field(@changeset, :default_profile)) or
                    Ecto.Changeset.get_field(@changeset, :default_profile) == ""
                }
              >
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
            <span class="helper-text">
              Profile assigned to newly discovered devices
            </span>
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
