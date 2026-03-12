defmodule YellowDog.Console.DiagnosticsLive.Dhcpv6Tab do
  @moduledoc """
  DHCPv6 query tab component for the diagnostics page.

  Provides form fields for DHCPv6 message testing with privileged port warning.
  """
  use Phoenix.Component
  use PhoenixDuskmoon.Component

  alias YellowDog.Console.DiagnosticsLive.Components.ResultDisplay
  alias YellowDog.Console.DiagnosticsLive.Components.QueryHistory

  @message_types [
    {"SOLICIT", "solicit"},
    {"REQUEST", "request"},
    {"RENEW", "renew"},
    {"REBIND", "rebind"},
    {"RELEASE", "release"},
    {"DECLINE", "decline"},
    {"INFORMATION-REQUEST", "information_request"}
  ]

  attr :tab, :map, required: true
  attr :display_mode, :atom, required: true
  attr :history_visible, :boolean, default: false

  def render(assigns) do
    assigns = assign(assigns, :message_types, @message_types)

    ~H"""
    <div class="card bg-surface shadow-xl">
      <div class="card-body">
        <h2 class="card-title">DHCPv6 Message Testing</h2>

        <div class="alert alert-warning mb-4">
          <.dm_mdi name="alert" class="stroke-current shrink-0 h-6 w-6" />
          <span>Port 546 requires root/administrator privileges. Messages sent to ff02::1:2:547</span>
        </div>

        <form phx-change="validate_dhcpv6" phx-submit="send_dhcpv6_query">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <%!-- Message Type --%>
            <div class="form-group">
              <label class="form-label">Message Type</label>
              <select
                name="dhcpv6_query[message_type]"
                aria-label="DHCPv6 message type"
                class="select w-full"
              >
                <%= for {label, value} <- @message_types do %>
                  <option
                    value={value}
                    selected={
                      (@tab.form[:message_type] || @tab.form["message_type"] || "solicit") == value
                    }
                  >
                    {label}
                  </option>
                <% end %>
              </select>
            </div>

            <%!-- DUID --%>
            <div class="form-group">
              <label class="form-label">DUID (Client Identifier)</label>
              <input
                type="text"
                name="dhcpv6_query[duid]"
                value={@tab.form[:duid] || @tab.form["duid"] || ""}
                placeholder="Auto-generate"
                class="input w-full"
              />
              <span class="helper-text">Hex string (leave empty for auto)</span>
            </div>

            <%!-- Transaction ID --%>
            <div class="form-group">
              <label class="form-label">Transaction ID</label>
              <input
                type="text"
                name="dhcpv6_query[transaction_id]"
                value={@tab.form[:transaction_id] || @tab.form["transaction_id"] || ""}
                placeholder="Auto-generate"
                class="input w-full"
              />
              <span class="helper-text">3-byte hex string (leave empty for auto)</span>
            </div>

            <%!-- IAID --%>
            <div class="form-group">
              <label class="form-label">IAID (Identity Association ID)</label>
              <input
                type="text"
                name="dhcpv6_query[iaid]"
                value={@tab.form[:iaid] || @tab.form["iaid"] || ""}
                placeholder="Auto-generate"
                class="input w-full"
              />
              <span class="helper-text">4-byte hex string (leave empty for auto)</span>
            </div>

            <%!-- Requested Options --%>
            <div class="form-group">
              <label class="form-label">Requested Options</label>
              <input
                type="text"
                name="dhcpv6_query[requested_options]"
                value={@tab.form[:requested_options] || @tab.form["requested_options"] || "23"}
                placeholder="23"
                class="input w-full"
              />
              <span class="helper-text">Comma-separated (23=DNS servers)</span>
            </div>

            <%!-- Timeout --%>
            <div class="form-group">
              <label class="form-label">Timeout (ms)</label>
              <input
                type="number"
                name="dhcpv6_query[timeout]"
                value={@tab.form[:timeout] || @tab.form["timeout"] || "10000"}
                placeholder="10000"
                min="1000"
                max="60000"
                class="input w-full"
              />
            </div>
          </div>

          <div class="card-actions justify-end mt-4">
            <button
              type="submit"
              class={["btn btn-primary", @tab.loading && "loading"]}
              disabled={@tab.loading}
              phx-disable-with="Sending..."
            >
              <%= if @tab.loading do %>
                <span
                  class="inline-block animate-spin rounded-full border-2 border-current border-t-transparent w-5 h-5"
                  role="status"
                >
                </span>
                Sending...
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
          protocol={:dhcpv6}
        />
      </div>
    </div>
    """
  end
end
