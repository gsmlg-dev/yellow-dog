defmodule YellowDog.Console.IdentityComponents do
  @moduledoc "Shared helper functions for Identity LiveView pages."

  @doc "Returns CSS class string for a host status badge."
  @spec status_badge_class(atom()) :: String.t()
  def status_badge_class(:pending), do: "badge badge-warning"
  def status_badge_class(:approved), do: "badge badge-success"
  def status_badge_class(:revoked), do: "badge badge-error"
  def status_badge_class(_), do: "badge"

  @doc "Returns CSS class string for an identity audit event badge."
  @spec event_badge_class(String.t()) :: String.t()
  def event_badge_class("host.registered"), do: "badge badge-info badge-sm"
  def event_badge_class("host.approved"), do: "badge badge-success badge-sm"
  def event_badge_class("host.revoked"), do: "badge badge-error badge-sm"
  def event_badge_class("host.key_rotated"), do: "badge badge-warning badge-sm"
  def event_badge_class("host.deleted"), do: "badge badge-error badge-outline badge-sm"
  def event_badge_class(_), do: "badge badge-sm"

  @doc "Formats a DateTime for display, returning \"-\" for nil."
  @spec format_time(DateTime.t() | nil) :: String.t()
  def format_time(nil), do: "-"
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  def format_time(_), do: "-"

  @doc "Formats a DateTime with seconds and UTC suffix for detail views."
  @spec format_time_detail(DateTime.t() | nil) :: String.t()
  def format_time_detail(nil), do: "-"
  def format_time_detail(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  def format_time_detail(_), do: "-"
end
