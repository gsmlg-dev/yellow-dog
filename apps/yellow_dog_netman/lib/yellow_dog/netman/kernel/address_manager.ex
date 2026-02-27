defmodule YellowDog.Netman.Kernel.AddressManager do
  @moduledoc """
  Manages IP addresses on network interfaces.

  Tracks current addresses via netlink events and provides
  commands to add/remove addresses.
  """

  use GenServer

  require Logger

  alias YellowDog.Netman.EventBus
  alias YellowDog.Netman.Kernel.Netlink

  @table :netman_addresses

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get all addresses for an interface."
  @spec get_addresses(String.t()) :: [map()]
  def get_addresses(interface) do
    case :ets.lookup(@table, interface) do
      [{_key, addresses}] -> addresses
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Get all addresses across all interfaces."
  @spec list_all() :: %{String.t() => [map()]}
  def list_all do
    try do
      :ets.tab2list(@table)
      |> Enum.into(%{}, fn {iface, addrs} -> {iface, addrs} end)
    rescue
      ArgumentError -> %{}
    end
  end

  @doc "Add an address to an interface via netlink."
  @spec add_address(String.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def add_address(interface, address, prefix_len) do
    Netlink.command(%{
      "cmd" => "addr_add",
      "interface" => interface,
      "address" => "#{address}/#{prefix_len}"
    })
  end

  @doc "Remove an address from an interface via netlink."
  @spec remove_address(String.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def remove_address(interface, address, prefix_len) do
    Netlink.command(%{
      "cmd" => "addr_del",
      "interface" => interface,
      "address" => "#{address}/#{prefix_len}"
    })
  end

  @doc "Flush all addresses on an interface."
  @spec flush(String.t()) :: :ok | {:error, term()}
  def flush(interface) do
    get_addresses(interface)
    |> Enum.each(fn addr ->
      remove_address(interface, addr.address, addr.prefix_len)
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
  def handle_info({:netlink_event, {:address_change, event}}, state) do
    handle_address_event(event)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Internal

  defp handle_address_event(%{"action" => action, "interface" => iface} = event) do
    addr = parse_address(event)

    case action do
      "add" ->
        existing = get_addresses(iface)

        unless Enum.any?(existing, &(&1.address == addr.address)) do
          :ets.insert(@table, {iface, [addr | existing]})
        end

      "del" ->
        existing = get_addresses(iface)
        updated = Enum.reject(existing, &(&1.address == addr.address))
        :ets.insert(@table, {iface, updated})

      _ ->
        :ok
    end

    action_atom = if action == "add", do: :add, else: :remove

    :telemetry.execute(
      [:yellow_dog, :netman, :kernel, :address_change],
      %{count: 1},
      %{interface: iface, action: action_atom, address: addr.address}
    )

    EventBus.publish("netman:address:#{iface}", {action_atom, addr})
  end

  defp handle_address_event(_), do: :ok

  defp parse_address(event) do
    {address, prefix_len} = parse_cidr(Map.get(event, "address", "0.0.0.0/0"))

    %{
      interface: Map.get(event, "interface"),
      address: address,
      prefix_len: prefix_len,
      family: parse_family(Map.get(event, "family", "inet")),
      scope: parse_scope(Map.get(event, "scope", "global"))
    }
  end

  defp parse_cidr(cidr) do
    case String.split(cidr, "/") do
      [addr, prefix] ->
        case Integer.parse(prefix) do
          {n, ""} -> {addr, n}
          _ -> {addr, 32}
        end

      [addr] ->
        {addr, 32}
    end
  end

  defp parse_family("inet"), do: :inet
  defp parse_family("inet6"), do: :inet6
  defp parse_family(_), do: :inet

  defp parse_scope("global"), do: :global
  defp parse_scope("link"), do: :link
  defp parse_scope("host"), do: :host
  defp parse_scope(_), do: :global
end
