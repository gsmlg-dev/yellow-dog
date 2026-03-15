defmodule YellowDog.Console.DiagnosticsLive.Components.HexDump do
  @moduledoc """
  Component for displaying binary data as xxd-style hex dump.

  Renders binary data in a format similar to the xxd command:
      00000000: 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f  ................
  """
  use Phoenix.Component

  alias YellowDog.Console.Diagnostics.HexFormatter

  @doc """
  Renders binary data as a hex dump.

  ## Attributes

    * `:binary` - The binary data to display
  """
  attr :binary, :any, required: true

  def render(assigns) do
    assigns = assign(assigns, :formatted, format_binary(assigns.binary))

    ~H"""
    <div class="font-mono text-xs">
      <%= if @formatted == "" do %>
        <span class="text-on-surface-variant italic">(empty)</span>
      <% else %>
        <pre class="whitespace-pre overflow-x-auto"><%= @formatted %></pre>
      <% end %>
    </div>
    """
  end

  @doc false
  def format_binary(nil), do: ""
  def format_binary(<<>>), do: ""
  def format_binary(binary) when is_binary(binary), do: HexFormatter.format(binary)
  def format_binary(_), do: ""
end
