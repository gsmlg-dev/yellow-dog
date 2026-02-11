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
  @spec format_datetime(DateTime.t() | nil) :: String.t()
  def format_datetime(nil), do: "-"
  def format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @doc "Formats a DateTime with seconds precision."
  @spec format_datetime_full(DateTime.t() | nil) :: String.t()
  def format_datetime_full(nil), do: "-"
  def format_datetime_full(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  @doc "Formats a DateTime as a relative time string (e.g. \"5m ago\")."
  @spec format_time_ago(DateTime.t() | nil) :: String.t()
  def format_time_ago(nil), do: "-"

  def format_time_ago(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end

  @doc "Formats a byte count as a human-readable string with space separator."
  @spec format_size(non_neg_integer() | any()) :: String.t()
  def format_size(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  def format_size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def format_size(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  def format_size(bytes) when is_integer(bytes), do: "#{bytes} B"
  def format_size(_), do: "-"
end
