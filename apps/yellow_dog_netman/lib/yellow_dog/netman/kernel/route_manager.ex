defmodule YellowDog.Netman.Kernel.RouteManager do
  @moduledoc """
  Manages network routes.

  Tracks current routes via netlink events and provides
  commands to add/remove routes with metric-based ordering.
  """

  use GenServer

  require Logger

  alias YellowDog.Netman.EventBus
  alias YellowDog.Netman.Kernel.Netlink

  @table :netman_routes

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get routes for a specific interface."
  @spec get_routes(String.t()) :: [map()]
  def get_routes(interface) do
    list_all()
    |> Enum.filter(&(&1.interface == interface))
  end

  @doc "List all routes."
  @spec list_all() :: [map()]
  def list_all do
    try do
      :ets.tab2list(@table)
      |> Enum.map(fn {_key, route} -> route end)
      |> Enum.sort_by(& &1.metric)
    rescue
      ArgumentError -> []
    end
  end

  @doc "Get the current default route."
  @spec default_route() :: map() | nil
  def default_route do
    list_all()
    |> Enum.find(&(&1.destination == "default" or &1.destination == "0.0.0.0/0"))
  end

  @doc "Add a route via netlink."
  @spec add_route(map()) :: :ok | {:error, term()}
  def add_route(route) do
    Netlink.command(%{
      "cmd" => "route_add",
      "destination" => Map.get(route, :destination, "default"),
      "gateway" => Map.get(route, :gateway),
      "interface" => Map.get(route, :interface),
      "metric" => Map.get(route, :metric, 100)
    })
  end

  @doc "Remove a route via netlink."
  @spec remove_route(map()) :: :ok | {:error, term()}
  def remove_route(route) do
    Netlink.command(%{
      "cmd" => "route_del",
      "destination" => Map.get(route, :destination, "default"),
      "gateway" => Map.get(route, :gateway),
      "interface" => Map.get(route, :interface)
    })
  end

  @doc "Remove all routes for an interface."
  @spec flush(String.t()) :: :ok
  def flush(interface) do
    get_routes(interface)
    |> Enum.each(fn route ->
      case remove_route(route) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to remove route #{route.destination} via #{route.gateway} on #{interface}: #{inspect(reason)}"
          )
      end
    end)
  end

  ## Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Netlink.subscribe()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info({:netlink_event, {:route_change, event}}, state) do
    handle_route_event(event)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Internal

  defp handle_route_event(%{"action" => action} = event) do
    route = parse_route(event)
    route_key = {route.destination, route.gateway, route.interface}

    case action do
      "add" ->
        :ets.insert(@table, {route_key, route})

      "del" ->
        :ets.delete(@table, route_key)

      _ ->
        :ok
    end

    action_atom = if action == "add", do: :add, else: :remove

    :telemetry.execute(
      [:yellow_dog, :netman, :kernel, :route_change],
      %{count: 1},
      %{action: action_atom, destination: route.destination, gateway: route.gateway}
    )

    table_id = Map.get(event, "table", 254)
    EventBus.publish("netman:route:#{table_id}", {action_atom, route})
  end

  defp handle_route_event(_), do: :ok

  defp parse_route(event) do
    %{
      destination: Map.get(event, "destination", "default"),
      gateway: Map.get(event, "gateway"),
      interface: Map.get(event, "interface", ""),
      metric: Map.get(event, "metric", 0),
      table: Map.get(event, "table", 254),
      protocol: parse_protocol(Map.get(event, "protocol", "unspec")),
      scope: parse_scope(Map.get(event, "scope", "universe"))
    }
  end

  defp parse_protocol("boot"), do: :boot
  defp parse_protocol("static"), do: :static
  defp parse_protocol("dhcp"), do: :dhcp
  defp parse_protocol("kernel"), do: :kernel
  defp parse_protocol(_), do: :unspec

  defp parse_scope("universe"), do: :universe
  defp parse_scope("link"), do: :link
  defp parse_scope("host"), do: :host
  defp parse_scope(_), do: :universe
end
