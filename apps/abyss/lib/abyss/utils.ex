defmodule Abyss.Utils do
  @moduledoc """
  Network utility functions for discovering interfaces and IP addresses.

  Provides functions to list and inspect network interfaces and their
  associated IP addresses on the host system.

  ## Usage Examples

  ### List all interfaces

      iex> Abyss.Utils.list_interfaces()
      ["lo", "eth0", "wlan0", "docker0"]

  ### List only active interfaces

      iex> Abyss.Utils.list_interfaces(only: :up)
      ["lo", "eth0", "wlan0"]

  ### List all IP addresses

      iex> Abyss.Utils.list_addresses()
      [
        %{interface: "lo", address: {127, 0, 0, 1}, family: :inet, netmask: {255, 0, 0, 0}},
        %{interface: "eth0", address: {192, 168, 1, 10}, family: :inet, netmask: {255, 255, 255, 0}},
        ...
      ]

  ### List only IPv4 addresses

      iex> Abyss.Utils.list_addresses(family: :inet)
      [
        %{interface: "lo", address: {127, 0, 0, 1}, family: :inet, netmask: {255, 0, 0, 0}},
        ...
      ]

  ### Get addresses for a specific interface

      iex> Abyss.Utils.get_interface_addresses("eth0")
      {:ok, [
        %{address: {192, 168, 1, 10}, family: :inet, netmask: {255, 255, 255, 0}},
        %{address: {0xfe80, 0, 0, 0, ...}, family: :inet6, netmask: {...}}
      ]}
  """

  @typedoc "IPv4 address tuple"
  @type ipv4_address :: {0..255, 0..255, 0..255, 0..255}

  @typedoc "IPv6 address tuple"
  @type ipv6_address ::
          {0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535}

  @typedoc "IP address (IPv4 or IPv6)"
  @type ip_address :: ipv4_address() | ipv6_address()

  @typedoc "Address family"
  @type family :: :inet | :inet6

  @typedoc "Interface flags from the system"
  @type interface_flag :: :up | :broadcast | :loopback | :pointtopoint | :running | :multicast

  @typedoc "Address information map"
  @type address_info :: %{
          required(:interface) => String.t(),
          required(:address) => ip_address(),
          required(:family) => family(),
          required(:netmask) => ip_address(),
          optional(:broadaddr) => ipv4_address(),
          optional(:dstaddr) => ip_address()
        }

  @typedoc "Interface information map"
  @type interface_info :: %{
          required(:name) => String.t(),
          required(:flags) => [interface_flag()],
          required(:addresses) => [address_info()],
          optional(:hwaddr) => [byte()]
        }

  @typedoc "Options for list_interfaces/1"
  @type list_interfaces_opts :: [
          only: :up | :down | :loopback | :multicast | :broadcast
        ]

  @typedoc "Options for list_addresses/1"
  @type list_addresses_opts :: [
          family: family(),
          interface: String.t(),
          only: :up | :loopback | :multicast
        ]

  @doc """
  List all network interface names on the host.

  Returns a list of interface name strings.

  ## Examples

      iex> Abyss.Utils.list_interfaces()
      ["lo", "eth0", "wlan0", "docker0", "br-abc123"]
  """
  @spec list_interfaces() :: [String.t()]
  def list_interfaces do
    list_interfaces([])
  end

  @doc """
  List network interface names with filtering options.

  ## Options

  - `:only` - Filter interfaces by flag:
    - `:up` - Only interfaces that are up
    - `:down` - Only interfaces that are down
    - `:loopback` - Only loopback interfaces
    - `:multicast` - Only interfaces supporting multicast
    - `:broadcast` - Only interfaces supporting broadcast

  ## Examples

      iex> Abyss.Utils.list_interfaces(only: :up)
      ["lo", "eth0", "wlan0"]

      iex> Abyss.Utils.list_interfaces(only: :loopback)
      ["lo"]

      iex> Abyss.Utils.list_interfaces(only: :multicast)
      ["eth0", "wlan0", "docker0"]
  """
  @spec list_interfaces(list_interfaces_opts()) :: [String.t()]
  def list_interfaces(opts) do
    case :inet.getifaddrs() do
      {:ok, addrs} ->
        addrs
        |> Enum.map(fn {name, props} -> {to_string(name), props} end)
        |> filter_interfaces_by_opts(opts)
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()

      {:error, _reason} ->
        []
    end
  end

  @doc """
  List all IP addresses on the host.

  Returns a list of address information maps containing the interface name,
  address, address family, and netmask.

  ## Examples

      iex> Abyss.Utils.list_addresses()
      [
        %{interface: "lo", address: {127, 0, 0, 1}, family: :inet, netmask: {255, 0, 0, 0}},
        %{interface: "lo", address: {0, 0, 0, 0, 0, 0, 0, 1}, family: :inet6, netmask: {...}},
        %{interface: "eth0", address: {192, 168, 1, 10}, family: :inet, netmask: {255, 255, 255, 0}},
        ...
      ]
  """
  @spec list_addresses() :: [address_info()]
  def list_addresses do
    list_addresses([])
  end

  @doc """
  List IP addresses with filtering options.

  ## Options

  - `:family` - Filter by address family:
    - `:inet` - IPv4 addresses only
    - `:inet6` - IPv6 addresses only
  - `:interface` - Filter by interface name (string)
  - `:only` - Filter by interface flag:
    - `:up` - Only addresses from interfaces that are up
    - `:loopback` - Only addresses from loopback interfaces
    - `:multicast` - Only addresses from interfaces supporting multicast

  ## Examples

      iex> Abyss.Utils.list_addresses(family: :inet)
      [
        %{interface: "lo", address: {127, 0, 0, 1}, family: :inet, netmask: {255, 0, 0, 0}},
        %{interface: "eth0", address: {192, 168, 1, 10}, family: :inet, netmask: {255, 255, 255, 0}}
      ]

      iex> Abyss.Utils.list_addresses(interface: "lo")
      [
        %{interface: "lo", address: {127, 0, 0, 1}, family: :inet, netmask: {255, 0, 0, 0}},
        %{interface: "lo", address: {0, 0, 0, 0, 0, 0, 0, 1}, family: :inet6, netmask: {...}}
      ]

      iex> Abyss.Utils.list_addresses(family: :inet, only: :up)
      [%{interface: "eth0", address: {192, 168, 1, 10}, family: :inet, ...}]
  """
  @spec list_addresses(list_addresses_opts()) :: [address_info()]
  def list_addresses(opts) do
    case :inet.getifaddrs() do
      {:ok, addrs} ->
        addrs
        |> Enum.map(fn {name, props} -> {to_string(name), props} end)
        |> filter_interfaces_by_opts(opts)
        |> Enum.flat_map(&extract_addresses/1)
        |> filter_addresses_by_family(opts[:family])

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Get detailed information about a specific network interface.

  Returns `{:ok, interface_info}` if the interface exists, or `{:error, :enodev}`
  if it doesn't.

  ## Examples

      iex> Abyss.Utils.get_interface("lo")
      {:ok, %{
        name: "lo",
        flags: [:up, :loopback, :running],
        hwaddr: [0, 0, 0, 0, 0, 0],
        addresses: [
          %{address: {127, 0, 0, 1}, family: :inet, netmask: {255, 0, 0, 0}},
          %{address: {0, 0, 0, 0, 0, 0, 0, 1}, family: :inet6, netmask: {...}}
        ]
      }}

      iex> Abyss.Utils.get_interface("nonexistent")
      {:error, :enodev}
  """
  @spec get_interface(String.t()) :: {:ok, interface_info()} | {:error, :enodev}
  def get_interface(interface_name) when is_binary(interface_name) do
    case :inet.getifaddrs() do
      {:ok, addrs} ->
        interface_charlist = String.to_charlist(interface_name)

        case List.keyfind(addrs, interface_charlist, 0) do
          nil ->
            {:error, :enodev}

          {_name, props} ->
            {:ok, build_interface_info(interface_name, props)}
        end

      {:error, _reason} ->
        {:error, :enodev}
    end
  end

  @doc """
  Get all IP addresses for a specific interface.

  Returns `{:ok, addresses}` if the interface exists, or `{:error, :enodev}`
  if it doesn't.

  ## Options

  - `:family` - Filter by address family (`:inet` or `:inet6`)

  ## Examples

      iex> Abyss.Utils.get_interface_addresses("eth0")
      {:ok, [
        %{address: {192, 168, 1, 10}, family: :inet, netmask: {255, 255, 255, 0}},
        %{address: {0xfe80, 0, 0, 0, ...}, family: :inet6, netmask: {...}}
      ]}

      iex> Abyss.Utils.get_interface_addresses("eth0", family: :inet)
      {:ok, [%{address: {192, 168, 1, 10}, family: :inet, netmask: {255, 255, 255, 0}}]}

      iex> Abyss.Utils.get_interface_addresses("nonexistent")
      {:error, :enodev}
  """
  @spec get_interface_addresses(String.t(), Keyword.t()) ::
          {:ok, [map()]} | {:error, :enodev}
  def get_interface_addresses(interface_name, opts \\ []) when is_binary(interface_name) do
    case get_interface(interface_name) do
      {:ok, info} ->
        addresses =
          info.addresses
          |> filter_addresses_by_family(opts[:family])
          |> Enum.map(&Map.delete(&1, :interface))

        {:ok, addresses}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get the primary IPv4 address for an interface.

  Returns `{:ok, address}` if found, or `{:error, :enodev}` if the interface
  doesn't exist or has no IPv4 address.

  ## Examples

      iex> Abyss.Utils.get_ipv4_address("eth0")
      {:ok, {192, 168, 1, 10}}

      iex> Abyss.Utils.get_ipv4_address("lo")
      {:ok, {127, 0, 0, 1}}

      iex> Abyss.Utils.get_ipv4_address("nonexistent")
      {:error, :enodev}
  """
  @spec get_ipv4_address(String.t()) :: {:ok, ipv4_address()} | {:error, :enodev}
  def get_ipv4_address(interface_name) when is_binary(interface_name) do
    case get_interface_addresses(interface_name, family: :inet) do
      {:ok, [%{address: addr} | _]} -> {:ok, addr}
      {:ok, []} -> {:error, :enodev}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get the primary IPv6 address for an interface.

  Returns `{:ok, address}` if found, or `{:error, :enodev}` if the interface
  doesn't exist or has no IPv6 address.

  ## Examples

      iex> Abyss.Utils.get_ipv6_address("eth0")
      {:ok, {0xfe80, 0, 0, 0, 0x1234, 0x5678, 0x9abc, 0xdef0}}

      iex> Abyss.Utils.get_ipv6_address("nonexistent")
      {:error, :enodev}
  """
  @spec get_ipv6_address(String.t()) :: {:ok, ipv6_address()} | {:error, :enodev}
  def get_ipv6_address(interface_name) when is_binary(interface_name) do
    case get_interface_addresses(interface_name, family: :inet6) do
      {:ok, [%{address: addr} | _]} -> {:ok, addr}
      {:ok, []} -> {:error, :enodev}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get the hardware (MAC) address for an interface.

  Returns `{:ok, hwaddr}` where hwaddr is a list of 6 bytes, or `{:error, :enodev}`
  if the interface doesn't exist or has no hardware address (e.g., loopback).

  ## Examples

      iex> Abyss.Utils.get_hwaddr("eth0")
      {:ok, [0x00, 0x1a, 0x2b, 0x3c, 0x4d, 0x5e]}

      iex> Abyss.Utils.get_hwaddr("lo")
      {:ok, [0, 0, 0, 0, 0, 0]}

      iex> Abyss.Utils.get_hwaddr("nonexistent")
      {:error, :enodev}
  """
  @spec get_hwaddr(String.t()) :: {:ok, [byte()]} | {:error, :enodev}
  def get_hwaddr(interface_name) when is_binary(interface_name) do
    case get_interface(interface_name) do
      {:ok, %{hwaddr: hwaddr}} when is_list(hwaddr) -> {:ok, hwaddr}
      {:ok, _} -> {:error, :enodev}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Format a hardware (MAC) address as a colon-separated string.

  ## Examples

      iex> Abyss.Utils.format_hwaddr([0x00, 0x1a, 0x2b, 0x3c, 0x4d, 0x5e])
      "00:1a:2b:3c:4d:5e"

      iex> Abyss.Utils.format_hwaddr([0, 0, 0, 0, 0, 0])
      "00:00:00:00:00:00"
  """
  @spec format_hwaddr([byte()]) :: String.t()
  def format_hwaddr(hwaddr) when is_list(hwaddr) do
    hwaddr
    |> Enum.map_join(":", fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
    |> String.downcase()
  end

  @doc """
  Format an IP address as a string.

  ## Examples

      iex> Abyss.Utils.format_address({192, 168, 1, 10})
      "192.168.1.10"

      iex> Abyss.Utils.format_address({0, 0, 0, 0, 0, 0, 0, 1})
      "::1"

      iex> Abyss.Utils.format_address({0xfe80, 0, 0, 0, 0x1234, 0x5678, 0x9abc, 0xdef0})
      "fe80::1234:5678:9abc:def0"
  """
  @spec format_address(ip_address()) :: String.t()
  def format_address(addr) when is_tuple(addr) do
    :inet.ntoa(addr) |> to_string()
  end

  # Private functions

  defp filter_interfaces_by_opts(interfaces, opts) do
    case opts[:only] do
      nil ->
        interfaces

      :up ->
        Enum.filter(interfaces, fn {_, props} -> :up in Keyword.get(props, :flags, []) end)

      :down ->
        Enum.filter(interfaces, fn {_, props} -> :up not in Keyword.get(props, :flags, []) end)

      :loopback ->
        Enum.filter(interfaces, fn {_, props} -> :loopback in Keyword.get(props, :flags, []) end)

      :multicast ->
        Enum.filter(interfaces, fn {_, props} -> :multicast in Keyword.get(props, :flags, []) end)

      :broadcast ->
        Enum.filter(interfaces, fn {_, props} -> :broadcast in Keyword.get(props, :flags, []) end)
    end
    |> filter_by_interface_name(opts[:interface])
  end

  defp filter_by_interface_name(interfaces, nil), do: interfaces

  defp filter_by_interface_name(interfaces, name) when is_binary(name) do
    Enum.filter(interfaces, fn {iface_name, _} -> iface_name == name end)
  end

  defp extract_addresses({interface_name, props}) do
    # Get all addr/netmask pairs
    addrs = Keyword.get_values(props, :addr)
    netmasks = Keyword.get_values(props, :netmask)
    broadaddrs = Keyword.get_values(props, :broadaddr)
    dstaddrs = Keyword.get_values(props, :dstaddr)

    # Pair addresses with their netmasks (they appear in order)
    addrs
    |> Enum.with_index()
    |> Enum.map(fn {addr, idx} ->
      netmask = Enum.at(netmasks, idx)
      family = address_family(addr)

      base = %{
        interface: interface_name,
        address: addr,
        family: family,
        netmask: netmask
      }

      # Add broadcast address if available and IPv4
      base =
        case {family, Enum.at(broadaddrs, idx)} do
          {:inet, broadaddr} when is_tuple(broadaddr) -> Map.put(base, :broadaddr, broadaddr)
          _ -> base
        end

      # Add destination address if available (for point-to-point)
      case Enum.at(dstaddrs, idx) do
        dstaddr when is_tuple(dstaddr) -> Map.put(base, :dstaddr, dstaddr)
        _ -> base
      end
    end)
  end

  defp filter_addresses_by_family(addresses, nil), do: addresses

  defp filter_addresses_by_family(addresses, :inet),
    do: Enum.filter(addresses, &(&1.family == :inet))

  defp filter_addresses_by_family(addresses, :inet6),
    do: Enum.filter(addresses, &(&1.family == :inet6))

  defp address_family({_, _, _, _}), do: :inet
  defp address_family({_, _, _, _, _, _, _, _}), do: :inet6

  defp build_interface_info(name, props) do
    flags = Keyword.get(props, :flags, [])
    hwaddr = Keyword.get(props, :hwaddr)

    addresses =
      extract_addresses({name, props})
      |> Enum.map(&Map.delete(&1, :interface))

    info = %{
      name: name,
      flags: flags,
      addresses: addresses
    }

    if hwaddr, do: Map.put(info, :hwaddr, hwaddr), else: info
  end
end
