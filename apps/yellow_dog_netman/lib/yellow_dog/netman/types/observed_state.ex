defmodule YellowDog.Netman.Types.ObservedState do
  @moduledoc """
  Represents the observed kernel network state.
  """

  @type link :: %{
          interface: String.t(),
          index: non_neg_integer(),
          state: :up | :down | :unknown,
          carrier: boolean(),
          mtu: pos_integer(),
          mac: String.t() | nil,
          kind: String.t() | nil
        }

  @type address :: %{
          interface: String.t(),
          address: String.t(),
          prefix_len: non_neg_integer(),
          family: :inet | :inet6,
          scope: atom()
        }

  @type route :: %{
          destination: String.t(),
          gateway: String.t() | nil,
          interface: String.t(),
          metric: non_neg_integer(),
          table: non_neg_integer(),
          protocol: atom(),
          scope: atom()
        }

  @type t :: %__MODULE__{
          links: %{String.t() => link()},
          addresses: %{String.t() => [address()]},
          routes: [route()]
        }

  defstruct links: %{},
            addresses: %{},
            routes: []

  @doc "Creates an empty observed state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Merges a link update into observed state."
  @spec put_link(t(), link()) :: t()
  def put_link(%__MODULE__{} = state, %{interface: iface} = link) do
    %{state | links: Map.put(state.links, iface, link)}
  end

  @doc "Removes a link from observed state."
  @spec remove_link(t(), String.t()) :: t()
  def remove_link(%__MODULE__{} = state, interface) do
    %{state | links: Map.delete(state.links, interface)}
  end

  @doc "Adds an address to observed state."
  @spec add_address(t(), address()) :: t()
  def add_address(%__MODULE__{} = state, %{interface: iface} = addr) do
    addresses = Map.update(state.addresses, iface, [addr], &[addr | &1])
    %{state | addresses: addresses}
  end

  @doc "Removes an address from observed state."
  @spec remove_address(t(), String.t(), String.t(), non_neg_integer() | nil) :: t()
  def remove_address(%__MODULE__{} = state, interface, address, prefix_len \\ nil) do
    addresses =
      Map.update(state.addresses, interface, [], fn addrs ->
        Enum.reject(addrs, fn a ->
          a.address == address and (prefix_len == nil or a.prefix_len == prefix_len)
        end)
      end)

    %{state | addresses: addresses}
  end

  @doc "Adds a route to observed state."
  @spec add_route(t(), route()) :: t()
  def add_route(%__MODULE__{} = state, route) do
    %{state | routes: [route | state.routes]}
  end

  @doc "Removes a route from observed state."
  @spec remove_route(t(), String.t(), String.t() | nil) :: t()
  def remove_route(%__MODULE__{} = state, destination, gateway) do
    routes =
      Enum.reject(state.routes, fn r ->
        r.destination == destination and r.gateway == gateway
      end)

    %{state | routes: routes}
  end
end
