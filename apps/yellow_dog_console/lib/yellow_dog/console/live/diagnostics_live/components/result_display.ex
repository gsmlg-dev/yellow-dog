defmodule YellowDog.Console.DiagnosticsLive.Components.ResultDisplay do
  @moduledoc """
  Component for displaying query results in struct or raw hex format.

  Supports toggling between formatted struct view and xxd-style hex dump,
  with copy-to-clipboard functionality for both request and response.
  """
  use Phoenix.Component
  use PhoenixDuskmoon.Component

  alias YellowDog.Console.DiagnosticsLive.Components.HexDump
  import YellowDog.Console.FormatHelper, only: [format_time: 1, format_ip: 1]
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
        <span class="text-sm text-on-surface-variant">
          {format_latency(@result.latency_ms)}
        </span>
        <span class="text-sm text-on-surface-variant">
          {format_time(@result.timestamp)}
        </span>
      </div>

      <%!-- Error Message --%>
      <%= if @result.error do %>
        <div class="alert alert-error">
          <.dm_mdi name="close-circle" class="h-6 w-6 shrink-0 stroke-current" />
          <span>{@result.error}</span>
        </div>
      <% end %>

      <%!-- Request Section --%>
      <div class="card bg-surface-container">
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
              <.dm_mdi name="content-copy" class="h-4 w-4" /> Copy
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
        <div class="card bg-surface-container">
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
                <.dm_mdi name="content-copy" class="h-4 w-4" /> Copy
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
          <div class="text-xs text-on-surface-variant mb-1">
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
        <div class="text-on-surface-variant italic">No responses received</div>
      <% end %>
    </div>
    """
  end

  # Formatting functions (public for testability)

  @doc false
  def status_text(:success), do: "Success"
  def status_text(:timeout), do: "Timeout"
  def status_text(:error), do: "Error"

  @doc false
  def format_latency(ms) when is_integer(ms) do
    cond do
      ms < 1 -> "<1ms"
      ms < 1000 -> "#{ms}ms"
      true -> "#{Float.round(ms / 1000, 2)}s"
    end
  end

  def format_latency(_), do: ""

  @doc false
  def format_struct(nil), do: "(empty)"

  # DNS messages have a nice to_string implementation
  def format_struct(%Message{} = message) do
    to_string(message)
  end

  # DHCPv4 messages have a nice to_string implementation
  def format_struct(%DHCPv4Message{} = message) do
    to_string(message)
  end

  # Fallback to inspect for other structs
  def format_struct(struct) do
    inspect(struct, pretty: true, limit: :infinity, width: 80)
  end

  @doc false
  def format_address(addr), do: format_ip(addr) || inspect(addr)
end
