defmodule YellowDog.Console.DiagnosticsLive.MdnsTab do
  @moduledoc """
  mDNS query tab component for the diagnostics page.

  Provides form fields for mDNS service discovery queries and displays
  multiple responses from the multicast group.
  """
  use Phoenix.Component

  alias YellowDog.Console.DiagnosticsLive.Components.ResultDisplay
  alias YellowDog.Console.DiagnosticsLive.Components.QueryHistory

  @query_types [
    {"PTR (Service Discovery)", "ptr"},
    {"SRV (Service Location)", "srv"},
    {"TXT (Service Info)", "txt"},
    {"A (IPv4 Address)", "a"},
    {"AAAA (IPv6 Address)", "aaaa"}
  ]

  attr :tab, :map, required: true
  attr :display_mode, :atom, required: true
  attr :history_visible, :boolean, default: false

  def render(assigns) do
    assigns = assign(assigns, :query_types, @query_types)

    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">mDNS Service Discovery</h2>

        <div class="alert alert-info mb-4">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            class="stroke-current shrink-0 w-6 h-6"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          <span>Queries are sent to multicast address 224.0.0.251:5353</span>
        </div>

        <form phx-change="validate_mdns" phx-submit="send_mdns_query">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <%!-- Service Type --%>
            <div class="form-control md:col-span-2">
              <label class="label">
                <span class="label-text">Service Type</span>
              </label>
              <input
                type="text"
                name="mdns_query[service_type]"
                value={@tab.form[:service_type] || @tab.form["service_type"] || "_http._tcp.local"}
                placeholder="_http._tcp.local"
                class="input input-bordered w-full"
                required
              />
              <label class="label">
                <span class="label-text-alt">e.g., _http._tcp.local, _printer._tcp.local</span>
              </label>
            </div>

            <%!-- Query Type --%>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Query Type</span>
              </label>
              <select
                name="mdns_query[query_type]"
                aria-label="mDNS query type"
                class="select select-bordered w-full"
              >
                <%= for {label, value} <- @query_types do %>
                  <option
                    value={value}
                    selected={(@tab.form[:query_type] || @tab.form["query_type"] || "ptr") == value}
                  >
                    {label}
                  </option>
                <% end %>
              </select>
            </div>

            <%!-- Timeout --%>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Timeout (ms)</span>
              </label>
              <input
                type="number"
                name="mdns_query[timeout]"
                value={@tab.form[:timeout] || @tab.form["timeout"] || "3000"}
                placeholder="3000"
                min="1000"
                max="30000"
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Collects all responses until timeout</span>
              </label>
            </div>
          </div>

          <div class="card-actions justify-end mt-4">
            <button
              type="submit"
              class={["btn btn-primary", @tab.loading && "loading"]}
              disabled={@tab.loading}
            >
              <%= if @tab.loading do %>
                <span class="loading loading-spinner loading-sm"></span> Discovering...
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
          protocol={:mdns}
        />
      </div>
    </div>
    """
  end
end
