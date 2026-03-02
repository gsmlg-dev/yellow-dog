defmodule YellowDog.Netman.Kernel.LinkMonitor do
  @moduledoc """
  Monitors network link state via netlink events.

  Maintains an ETS table of current link state and publishes
  `netman:link:<interface>` events to the EventBus.
  """

  use GenServer

  require Logger

  alias YellowDog.Netman.EventBus
  alias YellowDog.Netman.Kernel.Netlink

  @table :netman_links

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all known links."
  @spec list_links() :: [map()]
  def list_links do
    try do
      :ets.tab2list(@table)
      |> Enum.map(fn {_key, link} -> link end)
    rescue
      ArgumentError -> []
    end
  end

  @doc "Get a specific link by interface name."
  @spec get_link(String.t()) :: map() | nil
  def get_link(interface) do
    case :ets.lookup(@table, interface) do
      [{_key, link}] -> link
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  ## Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Netlink.subscribe()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info({:netlink_event, {:link_change, event}}, state) do
    handle_link_event(event)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Internal

  defp handle_link_event(%{"action" => "del", "interface" => iface}) do
    :ets.delete(@table, iface)

    :telemetry.execute(
      [:yellow_dog, :netman, :kernel, :link_change],
      %{count: 1},
      %{interface: iface, state: :removed, carrier: false}
    )

    EventBus.publish("netman:link:#{iface}", {:removed, iface})
  end

  defp handle_link_event(%{"interface" => iface} = event) do
    carrier = Map.get(event, "carrier", false)
    mtu = Map.get(event, "mtu", 1500)

    # Coerce carrier to boolean — netlink may send string "true"/"false"
    carrier =
      case carrier do
        b when is_boolean(b) -> b
        "true" -> true
        _ -> false
      end

    # Coerce mtu to integer
    mtu =
      case mtu do
        n when is_integer(n) and n > 0 -> n
        _ -> 1500
      end

    link = %{
      interface: iface,
      index: Map.get(event, "index", 0),
      state: parse_state(Map.get(event, "state", "unknown")),
      carrier: carrier,
      mtu: mtu,
      mac: Map.get(event, "mac"),
      kind: Map.get(event, "kind")
    }

    :ets.insert(@table, {iface, link})

    :telemetry.execute(
      [:yellow_dog, :netman, :kernel, :link_change],
      %{count: 1},
      %{interface: iface, state: link.state, carrier: link.carrier}
    )

    EventBus.publish("netman:link:#{iface}", {:link_update, link})
  end

  defp handle_link_event(event) do
    Logger.warning("Ignoring link event with missing fields: #{inspect(event)}")
    :ok
  end

  defp parse_state("up"), do: :up
  defp parse_state("down"), do: :down
  defp parse_state(_), do: :unknown
end
