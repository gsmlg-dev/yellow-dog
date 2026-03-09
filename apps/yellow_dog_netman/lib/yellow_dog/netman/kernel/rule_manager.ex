defmodule YellowDog.Netman.Kernel.RuleManager do
  @moduledoc """
  Manages policy routing rules via netlink.

  Tracks RTM_NEWRULE/RTM_DELRULE events for connection priority routing.
  """

  use GenServer

  alias YellowDog.Netman.Kernel.Netlink

  @type rule :: %{
          priority: non_neg_integer(),
          table: non_neg_integer(),
          source: String.t() | nil,
          destination: String.t() | nil,
          interface: String.t() | nil
        }

  @table :netman_rules

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list_rules() :: [rule()]
  def list_rules do
    try do
      :ets.tab2list(@table)
      |> Enum.map(fn {_key, rule} -> rule end)
    rescue
      ArgumentError -> []
    end
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Netlink.subscribe()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info({:netlink_event, {:rule_change, event}}, state) do
    handle_rule_event(event)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp handle_rule_event(%{"action" => "add"} = event) do
    rule = parse_rule(event)
    :ets.insert(@table, {rule.priority, rule})
  end

  defp handle_rule_event(%{"action" => "del"} = event) do
    rule = parse_rule(event)
    :ets.delete(@table, rule.priority)
  end

  defp handle_rule_event(_), do: :ok

  defp parse_rule(event) do
    %{
      priority: Map.get(event, "priority", 0),
      table: Map.get(event, "table", 254),
      source: Map.get(event, "source"),
      destination: Map.get(event, "destination"),
      interface: Map.get(event, "interface")
    }
  end
end
