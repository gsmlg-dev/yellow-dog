defmodule YellowDog.Console.Components.PoolFormComponent do
  @moduledoc """
  LiveComponent for address pool form (create/edit).

  Provides a modal form for managing DHCP address pools supporting both
  DHCPv4 (IPv4) and DHCPv6 (IPv6) protocols. Used by both pool management
  pages and settings pages.
  """

  use YellowDog.Console, :live_component

  alias YellowDog.Console.Settings.AddressPool

  @impl true
  def update(assigns, socket) do
    pool = assigns[:pool] || %AddressPool{}
    changeset = AddressPool.changeset(pool, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)
     |> assign(:pool, pool)}
  end

  @impl true
  def handle_event("validate", %{"address_pool" => pool_params}, socket) do
    changeset =
      socket.assigns.pool
      |> AddressPool.changeset(pool_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl true
  def handle_event("save", %{"address_pool" => pool_params}, socket) do
    changeset = AddressPool.changeset(socket.assigns.pool, pool_params)

    if changeset.valid? do
      pool = Ecto.Changeset.apply_changes(changeset)

      send(
        self(),
        {:pool_saved, socket.assigns.service_type, pool, socket.assigns.mode}
      )

      {:noreply, socket}
    else
      {:noreply, assign(socket, :changeset, Map.put(changeset, :action, :insert))}
    end
  end

  @impl true
  def handle_event("close", _params, socket) do
    send(self(), :close_pool_form)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    protocol = assigns[:protocol] || :ipv4
    mode = assigns[:mode] || :create
    assigns = assign(assigns, :protocol, protocol)
    assigns = assign(assigns, :mode, mode)

    ~H"""
    <div
      class="dialog-backdrop dialog-backdrop-show"
      phx-window-keydown="close"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div class="dialog dialog-md w-11/12 max-w-2xl">
        <h3 class="font-bold text-lg mb-4">
          {if @mode == :create, do: "Add", else: "Edit"} {protocol_name(@protocol)} Pool
        </h3>

        <.form
          id="pool-form"
          for={@changeset}
          phx-target={@myself}
          phx-change="validate"
          phx-debounce="blur"
          phx-submit="save"
          class="space-y-4"
        >
          <input type="hidden" name="address_pool[protocol]" value={@protocol} />
          <%= if @mode == :edit do %>
            <input
              type="hidden"
              name="address_pool[id]"
              value={Ecto.Changeset.get_field(@changeset, :id)}
            />
          <% end %>
          
    <!-- Pool Name -->
          <div class="form-group">
            <label class="form-label">Pool Name</label>
            <input
              type="text"
              name="address_pool[name]"
              value={Ecto.Changeset.get_field(@changeset, :name)}
              placeholder="e.g., office-network"
              disabled={@mode == :edit}
              class={[
                "input w-full",
                Keyword.has_key?(@changeset.errors, :name) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:name} />
            <%= if @mode == :edit do %>
              <span class="helper-text text-on-surface-variant">
                Pool name cannot be changed
              </span>
            <% end %>
          </div>
          
    <!-- Network (CIDR) -->
          <div class="form-group">
            <label class="form-label">Network (CIDR notation)</label>
            <input
              type="text"
              name="address_pool[network]"
              value={Ecto.Changeset.get_field(@changeset, :network)}
              placeholder={network_placeholder(@protocol)}
              class={[
                "input w-full",
                Keyword.has_key?(@changeset.errors, :network) && "input-error"
              ]}
            />
            <.input_error changeset={@changeset} field={:network} />
            <span class="helper-text">The subnet this pool belongs to (optional)</span>
          </div>
          
    <!-- IP Range -->
          <div class="grid grid-cols-2 gap-4">
            <div class="form-group">
              <label class="form-label">Range Start</label>
              <input
                type="text"
                name="address_pool[range_start]"
                value={Ecto.Changeset.get_field(@changeset, :range_start)}
                placeholder={range_placeholder(@protocol, :start)}
                class={[
                  "input w-full",
                  Keyword.has_key?(@changeset.errors, :range_start) &&
                    "input-error"
                ]}
              />
              <.input_error changeset={@changeset} field={:range_start} />
            </div>

            <div class="form-group">
              <label class="form-label">Range End</label>
              <input
                type="text"
                name="address_pool[range_end]"
                value={Ecto.Changeset.get_field(@changeset, :range_end)}
                placeholder={range_placeholder(@protocol, :end)}
                class={[
                  "input w-full",
                  Keyword.has_key?(@changeset.errors, :range_end) && "input-error"
                ]}
              />
              <.input_error changeset={@changeset} field={:range_end} />
            </div>
          </div>

          <%= if @protocol == :ipv4 do %>
            <!-- DHCPv4 Fields -->
            <div class="form-group">
              <label class="form-label">Lease Time (seconds)</label>
              <input
                type="number"
                name="address_pool[lease_time]"
                value={Ecto.Changeset.get_field(@changeset, :lease_time)}
                placeholder="3600"
                min="60"
                class={[
                  "input w-full",
                  Keyword.has_key?(@changeset.errors, :lease_time) && "input-error"
                ]}
              />
              <.input_error changeset={@changeset} field={:lease_time} />
              <span class="helper-text">Minimum 60 seconds. Common: 3600 (1h), 86400 (1d)</span>
            </div>

            <div class="form-group">
              <label class="form-label">Gateway (Optional)</label>
              <input
                type="text"
                name="address_pool[gateway]"
                value={Ecto.Changeset.get_field(@changeset, :gateway)}
                placeholder="192.168.1.1"
                class={[
                  "input w-full",
                  Keyword.has_key?(@changeset.errors, :gateway) && "input-error"
                ]}
              />
              <.input_error changeset={@changeset} field={:gateway} />
            </div>
          <% else %>
            <!-- DHCPv6 Fields -->
            <div class="grid grid-cols-2 gap-4">
              <div class="form-group">
                <label class="form-label">Preferred Lifetime (s)</label>
                <input
                  type="number"
                  name="address_pool[preferred_lifetime]"
                  value={Ecto.Changeset.get_field(@changeset, :preferred_lifetime)}
                  placeholder="3600"
                  min="60"
                  class={[
                    "input w-full",
                    Keyword.has_key?(@changeset.errors, :preferred_lifetime) &&
                      "input-error"
                  ]}
                />
                <.input_error changeset={@changeset} field={:preferred_lifetime} />
              </div>

              <div class="form-group">
                <label class="form-label">Valid Lifetime (s)</label>
                <input
                  type="number"
                  name="address_pool[valid_lifetime]"
                  value={Ecto.Changeset.get_field(@changeset, :valid_lifetime)}
                  placeholder="7200"
                  min="60"
                  class={[
                    "input w-full",
                    Keyword.has_key?(@changeset.errors, :valid_lifetime) &&
                      "input-error"
                  ]}
                />
                <.input_error changeset={@changeset} field={:valid_lifetime} />
              </div>
            </div>
          <% end %>
          
    <!-- DNS Servers (comma-separated) -->
          <div class="form-group">
            <label class="form-label">DNS Servers (Optional, comma-separated)</label>
            <input
              type="text"
              name="address_pool[dns_servers_str]"
              value={format_dns_servers(Ecto.Changeset.get_field(@changeset, :dns_servers))}
              placeholder={dns_placeholder(@protocol)}
              class={[
                "input w-full",
                Keyword.has_key?(@changeset.errors, :dns_servers) && "input-error"
              ]}
              phx-debounce="300"
            />
            <.input_error changeset={@changeset} field={:dns_servers} />
          </div>

          <div class="dialog-actions">
            <button type="button" phx-click="close" phx-target={@myself} class="btn btn-ghost">
              Cancel
            </button>
            <button
              type="submit"
              phx-disable-with="Saving..."
              class={["btn btn-primary", false]}
              disabled={!@changeset.valid?}
            >
              {if @mode == :create, do: "Add Pool", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp protocol_name(:ipv4), do: "DHCPv4"
  defp protocol_name(:ipv6), do: "DHCPv6"

  defp network_placeholder(:ipv4), do: "10.100.0.0/20"
  defp network_placeholder(:ipv6), do: "2001:db8::/48"

  defp range_placeholder(:ipv4, :start), do: "192.168.1.100"
  defp range_placeholder(:ipv4, :end), do: "192.168.1.200"
  defp range_placeholder(:ipv6, :start), do: "2001:db8::100"
  defp range_placeholder(:ipv6, :end), do: "2001:db8::200"

  defp dns_placeholder(:ipv4), do: "8.8.8.8, 8.8.4.4"
  defp dns_placeholder(:ipv6), do: "2001:4860:4860::8888, 2001:4860:4860::8844"

  defp format_dns_servers([]), do: ""
  defp format_dns_servers(nil), do: ""
  defp format_dns_servers(servers) when is_list(servers), do: Enum.join(servers, ", ")
end
