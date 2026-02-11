defmodule YellowDog.Console.NetbootComponents do
  @moduledoc "Shared function components for Netboot LiveView pages."
  use Phoenix.Component

  import YellowDog.Console.CoreComponents

  @doc "Renders a colored badge for a netboot device state atom."
  attr :state, :atom, required: true

  def state_badge(assigns) do
    {color, label} = state_display(assigns.state)
    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <.badge color={@color} size="sm">{@label}</.badge>
    """
  end

  defp state_display(:discovered), do: {"neutral", "Discovered"}
  defp state_display(:booting), do: {"warning", "Booting"}
  defp state_display(:installing), do: {"info", "Installing"}
  defp state_display(:installed), do: {"success", "Installed"}
  defp state_display(:failed), do: {"error", "Failed"}
  defp state_display(:reinstall_requested), do: {"warning", "Reinstall"}
  defp state_display(_), do: {"neutral", "Unknown"}

  @doc "Formats a DateTime for display, returning \"-\" for nil."
  def format_datetime(nil), do: "-"
  def format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @doc "Formats a DateTime with seconds precision."
  def format_datetime_full(nil), do: "-"
  def format_datetime_full(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  @doc "Formats a byte count as a human-readable string with space separator."
  def format_size(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  def format_size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def format_size(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  def format_size(bytes) when is_integer(bytes), do: "#{bytes} B"
  def format_size(_), do: "-"
end
