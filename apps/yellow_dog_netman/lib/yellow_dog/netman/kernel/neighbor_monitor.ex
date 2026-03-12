defmodule YellowDog.Netman.Kernel.NeighborMonitor do
  @moduledoc """
  Read-only ARP/NDP neighbor observation via netlink.

  Tracks RTM_NEWNEIGH/RTM_DELNEIGH events for neighbor cache visibility.
  """

  use GenServer

  alias YellowDog.Netman.Kernel.Netlink

  @type neighbor :: %{
          interface: String.t(),
          address: String.t(),
          mac: String.t() | nil,
          state:
            :reachable
            | :stale
            | :delay
            | :probe
            | :failed
            | :permanent
            | :incomplete
            | :noarp
            | :none
        }

  @table :netman_neighbors

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list_neighbors() :: [neighbor()]
  def list_neighbors do
    try do
      :ets.tab2list(@table)
      |> Enum.map(fn {_key, neighbor} -> neighbor end)
    rescue
      ArgumentError -> []
    end
  end

  @spec get_neighbors(String.t()) :: [neighbor()]
  def get_neighbors(interface) do
    list_neighbors()
    |> Enum.filter(&(&1.interface == interface))
  end

  @impl true
  def init(_opts) do
    try do: :ets.delete(@table), catch: (_, _ -> :ok)
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Netlink.subscribe()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info({:netlink_event, {:neighbor_change, event}}, state) do
    handle_neighbor_event(event)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp handle_neighbor_event(%{"action" => "add"} = event) do
    neighbor = parse_neighbor(event)
    key = {neighbor.interface, neighbor.address}
    :ets.insert(@table, {key, neighbor})
  end

  defp handle_neighbor_event(%{"action" => "del"} = event) do
    neighbor = parse_neighbor(event)
    key = {neighbor.interface, neighbor.address}
    :ets.delete(@table, key)
  end

  defp handle_neighbor_event(_), do: :ok

  defp parse_neighbor(event) do
    %{
      interface: Map.get(event, "interface", ""),
      address: Map.get(event, "address", ""),
      mac: Map.get(event, "mac"),
      state: parse_nud_state(Map.get(event, "state", "none"))
    }
  end

  defp parse_nud_state("reachable"), do: :reachable
  defp parse_nud_state("stale"), do: :stale
  defp parse_nud_state("delay"), do: :delay
  defp parse_nud_state("probe"), do: :probe
  defp parse_nud_state("failed"), do: :failed
  defp parse_nud_state("permanent"), do: :permanent
  defp parse_nud_state("incomplete"), do: :incomplete
  defp parse_nud_state("noarp"), do: :noarp
  defp parse_nud_state(_), do: :none
end
