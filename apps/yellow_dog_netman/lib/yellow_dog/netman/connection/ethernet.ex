defmodule YellowDog.Netman.Connection.Ethernet do
  @moduledoc """
  Ethernet-specific activation logic.

  Handles ethernet connection specifics like link detection,
  carrier monitoring, and MTU configuration.
  """

  alias YellowDog.Netman.Kernel.LinkMonitor

  @doc "Check if an interface is an ethernet device."
  @spec ethernet?(String.t()) :: boolean()
  def ethernet?(interface) do
    case LinkMonitor.get_link(interface) do
      %{kind: kind} when kind in [nil, "ethernet", "veth"] -> true
      _ -> false
    end
  end

  @doc "Check if an interface has carrier (cable connected)."
  @spec carrier?(String.t()) :: boolean()
  def carrier?(interface) do
    case LinkMonitor.get_link(interface) do
      %{carrier: true} -> true
      _ -> false
    end
  end

  @doc "Get the current MTU of an interface."
  @spec mtu(String.t()) :: pos_integer() | nil
  def mtu(interface) do
    case LinkMonitor.get_link(interface) do
      %{mtu: mtu} -> mtu
      _ -> nil
    end
  end
end
