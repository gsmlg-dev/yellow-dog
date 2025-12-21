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
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">DNS Query</h2>

        <form phx-change="validate_dns" phx-submit="send_dns_query">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <%!-- Query Name --%>
            <div class="form-control md:col-span-2">
              <label class="label">
                <span class="label-text">Domain Name</span>
              </label>
              <input
                type="text"
                name="dns_query[query_name]"
                value={@tab.form[:query_name] || @tab.form["query_name"]}
                placeholder="example.com"
                class="input input-bordered w-full"
                required
              />
            </div>

            <%!-- Record Type --%>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Record Type</span>
              </label>
              <select
                name="dns_query[record_type]"
                class="select select-bordered w-full"
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
            <div class="form-control">
              <label class="label">
                <span class="label-text">Protocol</span>
              </label>
              <select
                name="dns_query[protocol]"
                class="select select-bordered w-full"
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
            <div class="form-control">
              <label class="label">
                <span class="label-text">DNS Server</span>
              </label>
              <input
                type="text"
                name="dns_query[server]"
                value={@tab.form[:server] || @tab.form["server"] || "127.0.0.1"}
                placeholder="127.0.0.1"
                class="input input-bordered w-full"
              />
            </div>

            <%!-- Port --%>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Port</span>
              </label>
              <input
                type="number"
                name="dns_query[port]"
                value={@tab.form[:port] || @tab.form["port"] || "53"}
                placeholder="53"
                min="1"
                max="65535"
                class="input input-bordered w-full"
              />
            </div>

            <%!-- Recursion Desired --%>
            <div class="form-control">
              <label class="label cursor-pointer">
                <span class="label-text">Recursion Desired</span>
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
            <div class="form-control">
              <label class="label">
                <span class="label-text">Timeout (ms)</span>
              </label>
              <input
                type="number"
                name="dns_query[timeout]"
                value={@tab.form[:timeout] || @tab.form["timeout"] || "5000"}
                placeholder="5000"
                min="1000"
                max="30000"
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
