defmodule YellowDog.Console.DiagnosticsLive.Dhcpv4Tab do
  @moduledoc """
  DHCPv4 query tab component for the diagnostics page.

  Provides form fields for DHCPv4 message testing with privileged port warning.
  """
  use Phoenix.Component

  alias YellowDog.Console.DiagnosticsLive.Components.ResultDisplay
  alias YellowDog.Console.DiagnosticsLive.Components.QueryHistory

  @message_types [
    {"DISCOVER", "discover"},
    {"REQUEST", "request"},
    {"DECLINE", "decline"},
    {"RELEASE", "release"},
    {"INFORM", "inform"}
  ]

  attr :tab, :map, required: true
  attr :display_mode, :atom, required: true
  attr :history_visible, :boolean, default: false

  def render(assigns) do
    assigns = assign(assigns, :message_types, @message_types)

    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">DHCPv4 Message Testing</h2>

        <div class="alert alert-warning mb-4">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="stroke-current shrink-0 h-6 w-6"
            fill="none"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
            />
          </svg>
          <span>Port 68 requires root/administrator privileges</span>
        </div>

        <form phx-change="validate_dhcpv4" phx-submit="send_dhcpv4_query">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <%!-- Message Type --%>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Message Type</span>
              </label>
              <select
                name="dhcpv4_query[message_type]"
                class="select select-bordered w-full"
              >
                <%= for {label, value} <- @message_types do %>
                  <option
                    value={value}
                    selected={
                      (@tab.form[:message_type] || @tab.form["message_type"] || "discover") == value
                    }
                  >
                    {label}
                  </option>
                <% end %>
              </select>
            </div>

            <%!-- Client MAC --%>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Client MAC Address</span>
              </label>
              <input
                type="text"
                name="dhcpv4_query[client_mac]"
                value={@tab.form[:client_mac] || @tab.form["client_mac"] || ""}
                placeholder="Auto-generate"
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Format: xx:xx:xx:xx:xx:xx (leave empty for auto)</span>
              </label>
            </div>

            <%!-- Transaction ID --%>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Transaction ID</span>
              </label>
              <input
                type="text"
                name="dhcpv4_query[transaction_id]"
                value={@tab.form[:transaction_id] || @tab.form["transaction_id"] || ""}
                placeholder="Auto-generate"
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Hex string (leave empty for auto)</span>
              </label>
            </div>

            <%!-- Requested Options --%>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Requested Options</span>
              </label>
              <input
                type="text"
                name="dhcpv4_query[requested_options]"
                value={@tab.form[:requested_options] || @tab.form["requested_options"] || "1,3,6,15"}
                placeholder="1,3,6,15"
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Comma-separated option codes</span>
              </label>
            </div>

            <%!-- Timeout --%>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Timeout (ms)</span>
              </label>
              <input
                type="number"
                name="dhcpv4_query[timeout]"
                value={@tab.form[:timeout] || @tab.form["timeout"] || "10000"}
                placeholder="10000"
                min="1000"
                max="60000"
                class="input input-bordered w-full"
              />
            </div>
          </div>

          <div class="card-actions justify-end mt-4">
            <button
              type="submit"
              class={["btn btn-primary", @tab.loading && "loading"]}
              disabled={@tab.loading}
            >
              <%= if @tab.loading do %>
                <span class="loading loading-spinner loading-sm"></span> Sending...
              <% else %>
                Send Message
              <% end %>
            </button>
          </div>
        </form>

        <%!-- Results --%>
        <%= if @tab.current_result do %>
          <div class="divider">Results</div>
          <ResultDisplay.render result={@tab.current_result} mode={@display_mode} />
        <% end %>

        <%!-- History --%>
        <QueryHistory.render
          history={@tab.history}
          visible={@history_visible}
          protocol={:dhcpv4}
        />
      </div>
    </div>
    """
  end
end
