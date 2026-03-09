defmodule YellowDog.Console.DiagnosticsLive.DnsTab do
  @moduledoc """
  DNS query tab component for the diagnostics page.

  Provides form fields for DNS query parameters and displays results.
  """
  use Phoenix.Component

  alias YellowDog.Console.DiagnosticsLive.Components.ResultDisplay
  alias YellowDog.Console.DiagnosticsLive.Components.QueryHistory

  @record_types [
    {"A", "a"},
    {"AAAA", "aaaa"},
    {"MX", "mx"},
    {"TXT", "txt"},
    {"CNAME", "cname"},
    {"NS", "ns"},
    {"SOA", "soa"},
    {"PTR", "ptr"},
    {"SRV", "srv"}
  ]

  @protocols [
    {"UDP", "udp"},
    {"TCP", "tcp"}
  ]

  attr :tab, :map, required: true
  attr :display_mode, :atom, required: true
  attr :history_visible, :boolean, default: false

  def render(assigns) do
    assigns = assign(assigns, :record_types, @record_types)
    assigns = assign(assigns, :protocols, @protocols)

    ~H"""
    <div class="card bg-surface shadow-xl">
      <div class="card-body">
        <h2 class="card-title">DNS Query</h2>

        <form phx-change="validate_dns" phx-submit="send_dns_query">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <%!-- Query Name --%>
            <div class="form-group md:col-span-2">
              <label class="form-label">Domain Name</label>
              <input
                type="text"
                name="dns_query[query_name]"
                value={@tab.form[:query_name] || @tab.form["query_name"]}
                placeholder="example.com"
                class="input w-full"
                required
              />
            </div>

            <%!-- Record Type --%>
            <div class="form-group">
              <label class="form-label">Record Type</label>
              <select
                name="dns_query[record_type]"
                aria-label="DNS record type"
                class="select w-full"
              >
                <%= for {label, value} <- @record_types do %>
                  <option
                    value={value}
                    selected={(@tab.form[:record_type] || @tab.form["record_type"] || "a") == value}
                  >
                    {label}
                  </option>
                <% end %>
              </select>
            </div>

            <%!-- Protocol --%>
            <div class="form-group">
              <label class="form-label">Protocol</label>
              <select
                name="dns_query[protocol]"
                aria-label="DNS protocol"
                class="select w-full"
              >
                <%= for {label, value} <- @protocols do %>
                  <option
                    value={value}
                    selected={(@tab.form[:protocol] || @tab.form["protocol"] || "udp") == value}
                  >
                    {label}
                  </option>
                <% end %>
              </select>
            </div>

            <%!-- Server --%>
            <div class="form-group">
              <label class="form-label">DNS Server</label>
              <input
                type="text"
                name="dns_query[server]"
                value={@tab.form[:server] || @tab.form["server"] || "127.0.0.1"}
                placeholder="127.0.0.1"
                class="input w-full"
              />
            </div>

            <%!-- Port --%>
            <div class="form-group">
              <label class="form-label">Port</label>
              <input
                type="number"
                name="dns_query[port]"
                value={@tab.form[:port] || @tab.form["port"] || "53"}
                placeholder="53"
                min="1"
                max="65535"
                class="input w-full"
              />
            </div>

            <%!-- Recursion Desired --%>
            <div class="form-group">
              <label class="form-label cursor-pointer">
                Recursion Desired
                <input
                  type="checkbox"
                  name="dns_query[recursion_desired]"
                  value="true"
                  checked={
                    (@tab.form[:recursion_desired] || @tab.form["recursion_desired"] || "true") ==
                      "true"
                  }
                  class="checkbox checkbox-primary"
                />
              </label>
            </div>

            <%!-- Timeout --%>
            <div class="form-group">
              <label class="form-label">Timeout (ms)</label>
              <input
                type="number"
                name="dns_query[timeout]"
                value={@tab.form[:timeout] || @tab.form["timeout"] || "5000"}
                placeholder="5000"
                min="1000"
                max="30000"
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
                <span class="inline-block animate-spin rounded-full border-2 border-current border-t-transparent w-5 h-5" role="status"></span> Sending...
              <% else %>
                Send Query
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
          protocol={:dns}
        />
      </div>
    </div>
    """
  end
end
