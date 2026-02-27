defmodule YellowDog.Netman.Test.MockNetlink do
  @moduledoc """
  Simulated kernel netlink events for testing.

  Sends mock events to the Netlink GenServer which dispatches
  them to subscribers (LinkMonitor, AddressManager, etc).
  """

  alias YellowDog.Netman.Kernel.Netlink

  @doc "Simulate a link appearing."
  def link_up(interface, opts \\ []) do
    event = %{
      "type" => "link_change",
      "action" => "add",
      "interface" => interface,
      "index" => Keyword.get(opts, :index, 1),
      "state" => "up",
      "carrier" => Keyword.get(opts, :carrier, true),
      "mtu" => Keyword.get(opts, :mtu, 1500),
      "mac" => Keyword.get(opts, :mac, "aa:bb:cc:dd:ee:ff"),
      "kind" => Keyword.get(opts, :kind, nil)
    }

    send_event(event)
  end

  @doc "Simulate a link going down."
  def link_down(interface) do
    event = %{
      "type" => "link_change",
      "action" => "change",
      "interface" => interface,
      "state" => "down",
      "carrier" => false,
      "mtu" => 1500
    }

    send_event(event)
  end

  @doc "Simulate a link being removed."
  def link_removed(interface) do
    event = %{
      "type" => "link_change",
      "action" => "del",
      "interface" => interface
    }

    send_event(event)
  end

  @doc "Simulate carrier change (cable plug/unplug)."
  def carrier_change(interface, carrier?) do
    event = %{
      "type" => "link_change",
      "action" => "change",
      "interface" => interface,
      "state" => if(carrier?, do: "up", else: "down"),
      "carrier" => carrier?,
      "mtu" => 1500
    }

    send_event(event)
  end

  @doc "Simulate an address being added."
  def address_added(interface, address, opts \\ []) do
    event = %{
      "type" => "address_change",
      "action" => "add",
      "interface" => interface,
      "address" => address,
      "family" => Keyword.get(opts, :family, "inet"),
      "scope" => Keyword.get(opts, :scope, "global")
    }

    send_event(event)
  end

  @doc "Simulate an address being removed."
  def address_removed(interface, address) do
    event = %{
      "type" => "address_change",
      "action" => "del",
      "interface" => interface,
      "address" => address,
      "family" => "inet",
      "scope" => "global"
    }

    send_event(event)
  end

  @doc "Simulate a route being added."
  def route_added(opts) do
    event = %{
      "type" => "route_change",
      "action" => "add",
      "destination" => Keyword.get(opts, :destination, "default"),
      "gateway" => Keyword.get(opts, :gateway),
      "interface" => Keyword.get(opts, :interface, "eth0"),
      "metric" => Keyword.get(opts, :metric, 100),
      "table" => Keyword.get(opts, :table, 254),
      "protocol" => Keyword.get(opts, :protocol, "dhcp"),
      "scope" => Keyword.get(opts, :scope, "universe")
    }

    send_event(event)
  end

  @doc "Simulate a route being removed."
  def route_removed(opts) do
    event = %{
      "type" => "route_change",
      "action" => "del",
      "destination" => Keyword.get(opts, :destination, "default"),
      "gateway" => Keyword.get(opts, :gateway),
      "interface" => Keyword.get(opts, :interface, "eth0")
    }

    send_event(event)
  end

  @doc "Simulate a policy routing rule being added."
  def rule_added(opts \\ []) do
    event = %{
      "type" => "rule_change",
      "action" => "add",
      "priority" => Keyword.get(opts, :priority, 0),
      "table" => Keyword.get(opts, :table, 254),
      "source" => Keyword.get(opts, :source),
      "destination" => Keyword.get(opts, :destination),
      "interface" => Keyword.get(opts, :interface)
    }

    send_event(event)
  end

  @doc "Simulate a policy routing rule being removed."
  def rule_removed(opts \\ []) do
    event = %{
      "type" => "rule_change",
      "action" => "del",
      "priority" => Keyword.get(opts, :priority, 0),
      "table" => Keyword.get(opts, :table, 254)
    }

    send_event(event)
  end

  @doc "Simulate a neighbor (ARP/NDP) entry being added."
  def neighbor_added(interface, address, opts \\ []) do
    event = %{
      "type" => "neighbor_change",
      "action" => "add",
      "interface" => interface,
      "address" => address,
      "mac" => Keyword.get(opts, :mac),
      "state" => Keyword.get(opts, :state, "reachable")
    }

    send_event(event)
  end

  @doc "Simulate a neighbor (ARP/NDP) entry being removed."
  def neighbor_removed(interface, address) do
    event = %{
      "type" => "neighbor_change",
      "action" => "del",
      "interface" => interface,
      "address" => address
    }

    send_event(event)
  end

  defp send_event(event) do
    send(Netlink, {:mock_event, event})
    # Small delay to allow event propagation
    Process.sleep(10)
  end
end
