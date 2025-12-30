defmodule YellowDog.Console.DiagnosticsLive.Components.ResultDisplay do
  @moduledoc """
  Component for displaying query results in struct or raw hex format.

  Supports toggling between formatted struct view and xxd-style hex dump,
  with copy-to-clipboard functionality for both request and response.
  """
  use Phoenix.Component

  alias YellowDog.Console.DiagnosticsLive.Components.HexDump
  alias DNS.Message
  alias DHCPv4.Message, as: DHCPv4Message

  @doc """
  Renders the result display with request and response sections.

  ## Attributes

    * `:result` - The QueryResult struct to display
    * `:mode` - Display mode, either :struct or :raw
  """
  attr :result, :map, required: true
  attr :mode, :atom, default: :struct

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- Status Badge --%>
      <div class="flex items-center gap-2">
        <span class={[
          "badge",
          @result.status == :success && "badge-success",
          @result.status == :timeout && "badge-warning",
          @result.status == :error && "badge-error"
        ]}>
          {status_text(@result.status)}
        </span>
        <span class="text-sm text-base-content/70">
          {format_latency(@result.latency_ms)}
        </span>
        <span class="text-sm text-base-content/50">
          {format_timestamp(@result.timestamp)}
        </span>
      </div>

      <%!-- Error Message --%>
      <%= if @result.error do %>
        <div class="alert alert-error">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-6 w-6 shrink-0 stroke-current"
            fill="none"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          <span>{@result.error}</span>
        </div>
      <% end %>

      <%!-- Request Section --%>
      <div class="card bg-base-200">
        <div class="card-body p-4">
          <div class="flex justify-between items-center">
            <h3 class="card-title text-sm">Request</h3>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              phx-hook="CopyToClipboard"
              id="copy-request-btn"
              data-target="request-content"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
                />
              </svg>
              Copy
            </button>
          </div>
          <div id="request-content" class="overflow-x-auto">
            <%= if @mode == :struct do %>
              <pre class="text-xs font-mono whitespace-pre-wrap"><%= format_struct(@result.request_struct) %></pre>
            <% else %>
              <HexDump.render binary={@result.request_binary} />
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Response Section --%>
      <%= if @result.response_struct || @result.response_binary || @result.sources != [] do %>
        <div class="card bg-base-200">
          <div class="card-body p-4">
            <div class="flex justify-between items-center">
              <h3 class="card-title text-sm">Response</h3>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-hook="CopyToClipboard"
                id="copy-response-btn"
                data-target="response-content"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-4 w-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
                  />
                </svg>
                Copy
              </button>
            </div>
            <div id="response-content" class="overflow-x-auto">
              <%= if @result.sources != [] do %>
                <%!-- Multiple sources (mDNS) --%>
                <.render_sources sources={@result.sources} mode={@mode} />
              <% else %>
                <%= if @mode == :struct do %>
                  <pre class="text-xs font-mono whitespace-pre-wrap"><%= format_struct(@result.response_struct) %></pre>
                <% else %>
                  <HexDump.render binary={@result.response_binary} />
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders multiple response sources (for mDNS multicast responses).
  """
  attr :sources, :list, required: true
  attr :mode, :atom, default: :struct

  def render_sources(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= for {source, idx} <- Enum.with_index(@sources) do %>
        <div class="border-l-2 border-primary pl-3">
          <div class="text-xs text-base-content/70 mb-1">
            Source {idx + 1}: {format_address(source.address)}:{source.port}
          </div>
          <%= if @mode == :struct do %>
            <pre class="text-xs font-mono whitespace-pre-wrap"><%= format_struct(source.response_struct) %></pre>
          <% else %>
            <HexDump.render binary={source.response_binary} />
          <% end %>
        </div>
      <% end %>
      <%= if @sources == [] do %>
        <div class="text-base-content/50 italic">No responses received</div>
      <% end %>
    </div>
    """
  end

  # Private functions

  defp status_text(:success), do: "Success"
  defp status_text(:timeout), do: "Timeout"
  defp status_text(:error), do: "Error"

  defp format_latency(ms) when is_integer(ms) do
    cond do
      ms < 1 -> "<1ms"
      ms < 1000 -> "#{ms}ms"
      true -> "#{Float.round(ms / 1000, 2)}s"
    end
  end

  defp format_latency(_), do: ""

  defp format_timestamp(nil), do: ""

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_struct(nil), do: "(empty)"

  # DNS messages have a nice to_string implementation
  defp format_struct(%Message{} = message) do
    to_string(message)
  end

  # DHCPv4 messages have a nice to_string implementation
  defp format_struct(%DHCPv4Message{} = message) do
    to_string(message)
  end

  # Fallback to inspect for other structs
  defp format_struct(struct) do
    inspect(struct, pretty: true, limit: :infinity, width: 80)
  end

  defp format_address({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_address({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
  end

  defp format_address(addr) when is_binary(addr), do: addr
  defp format_address(addr), do: inspect(addr)
end
