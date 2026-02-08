defmodule YellowDog.Console.DiagnosticsLive.Components.QueryHistory do
  @moduledoc """
  Collapsible component for displaying query history.

  Shows up to 10 previous queries with timestamp, status, and parameters.
  Allows restoring previous queries to the form.
  """
  use Phoenix.Component

  import YellowDog.Console.FormatHelper, only: [format_time: 1]

  @doc """
  Renders the query history panel.

  ## Attributes

    * `:history` - List of QueryResult structs
    * `:visible` - Whether the history panel is expanded
    * `:protocol` - Protocol type for display formatting (:dns, :mdns, :dhcpv4, :dhcpv6)
  """
  attr :history, :list, required: true
  attr :visible, :boolean, default: false
  attr :protocol, :atom, required: true

  def render(assigns) do
    ~H"""
    <div class="collapse collapse-arrow bg-base-200 mt-4">
      <input type="checkbox" checked={@visible} phx-click="toggle_history" />
      <div class="collapse-title text-sm font-medium">
        Query History <span class="badge badge-sm badge-neutral ml-2">{length(@history)}</span>
      </div>
      <div class="collapse-content">
        <%= if @history == [] do %>
          <p class="text-base-content/50 text-sm italic py-2">No queries yet</p>
        <% else %>
          <div class="space-y-2">
            <%= for entry <- @history do %>
              <div
                class="flex items-center justify-between p-2 rounded bg-base-100 hover:bg-base-300 cursor-pointer"
                phx-click="select_history"
                phx-value-id={entry.id}
              >
                <div class="flex items-center gap-2">
                  <span class={[
                    "badge badge-xs",
                    entry.status == :success && "badge-success",
                    entry.status == :timeout && "badge-warning",
                    entry.status == :error && "badge-error"
                  ]}>
                  </span>
                  <span class="text-xs font-mono">
                    {format_entry_summary(entry, @protocol)}
                  </span>
                </div>
                <div class="flex items-center gap-2 text-xs text-base-content/50">
                  <span>{format_latency(entry.latency_ms)}</span>
                  <span>{format_time(entry.timestamp)}</span>
                </div>
              </div>
            <% end %>
          </div>
          <div class="mt-3 flex justify-end">
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              phx-click="clear_history"
            >
              Clear History
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_entry_summary(entry, :dns) do
    name = entry.params[:query_name] || entry.params["query_name"] || "?"
    type = entry.params[:record_type] || entry.params["record_type"] || "A"
    "#{name} (#{String.upcase(to_string(type))})"
  end

  defp format_entry_summary(entry, :mdns) do
    service = entry.params[:service_type] || entry.params["service_type"] || "?"
    "#{service}"
  end

  defp format_entry_summary(entry, :dhcpv4) do
    type = entry.params[:message_type] || entry.params["message_type"] || "?"
    mac = entry.params[:client_mac] || entry.params["client_mac"] || ""
    mac_short = if mac != "", do: " (#{String.slice(mac, -8, 8)})", else: ""
    "#{String.upcase(to_string(type))}#{mac_short}"
  end

  defp format_entry_summary(entry, :dhcpv6) do
    type = entry.params[:message_type] || entry.params["message_type"] || "?"
    "#{String.upcase(to_string(type))}"
  end

  defp format_entry_summary(_entry, _protocol), do: "Query"

  defp format_latency(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  defp format_latency(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)}s"
  defp format_latency(_), do: ""
end
