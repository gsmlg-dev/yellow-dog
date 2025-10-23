defmodule DHCPv4.Config do
  import Bitwise

  @moduledoc """
  DHCP Server configuration schema and validation.

  Provides structured configuration for DHCP server with validation
  and sensible defaults.
  """

  @type t :: %__MODULE__{
          subnet: :inet.ip4_address(),
          netmask: :inet.ip4_address(),
          range_start: :inet.ip4_address(),
          range_end: :inet.ip4_address(),
          gateway: :inet.ip4_address() | nil,
          dns_servers: [:inet.ip4_address()],
          lease_time: integer(),
          options: [DHCPv4.Message.Option.t()]
        }

  defstruct [
    :subnet,
    :netmask,
    :range_start,
    :range_end,
    :gateway,
    dns_servers: [],
    lease_time: 3600,
    options: []
  ]

  @doc """
  Create a new DHCP configuration from keyword options.

  ## Options

    * `:subnet` - Network subnet address (required)
    * `:netmask` - Subnet mask (required)
    * `:range_start` - Start of IP range (required)
    * `:range_end` - End of IP range (required)
    * `:gateway` - Default gateway (optional)
    * `:dns_servers` - List of DNS servers (default: [])
    * `:lease_time` - Lease duration in seconds (default: 3600)
    * `:options` - Additional DHCP options (default: [])

  ## Examples

      iex> config = DHCPv4.Config.new(
      ...>   subnet: {192, 168, 1, 0},
      ...>   netmask: {255, 255, 255, 0},
      ...>   range_start: {192, 168, 1, 100},
      ...>   range_end: {192, 168, 1, 200},
      ...>   gateway: {192, 168, 1, 1},
      ...>   dns_servers: [{8, 8, 8, 8}, {8, 8, 4, 4}],
      ...>   lease_time: 7200
      ...> )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts) do
    config = struct!(__MODULE__, opts)

    with :ok <- validate_config(config) do
      {:ok, config}
    end
  end

  @doc """
  Create a new DHCP configuration from keyword options, raising on errors.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Validate configuration and return error if any issues found.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(config) do
    validate_config(config)
  end

  defp validate_config(config) do
    cond do
      not is_valid_ip(config.subnet) ->
        {:error, "Invalid subnet address"}

      not is_valid_ip(config.netmask) ->
        {:error, "Invalid netmask"}

      not is_valid_ip(config.range_start) ->
        {:error, "Invalid range_start address"}

      not is_valid_ip(config.range_end) ->
        {:error, "Invalid range_end address"}

      config.gateway && not is_valid_ip(config.gateway) ->
        {:error, "Invalid gateway address"}

      not in_subnet?(config.range_start, config.subnet, config.netmask) ->
        {:error, "range_start not in subnet"}

      not in_subnet?(config.range_end, config.subnet, config.netmask) ->
        {:error, "range_end not in subnet"}

      ip_to_int(config.range_start) > ip_to_int(config.range_end) ->
        {:error, "range_start must be before range_end"}

      Enum.any?(config.dns_servers, &(!is_valid_ip(&1))) ->
        {:error, "Invalid DNS server address"}

      config.lease_time < 60 ->
        {:error, "lease_time must be at least 60 seconds"}

      true ->
        :ok
    end
  end

  defp is_valid_ip({a, b, c, d}) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
    do: true

  defp is_valid_ip(_), do: false

  defp in_subnet?(ip, subnet, netmask) do
    ip_int = ip_to_int(ip)
    subnet_int = ip_to_int(subnet)
    netmask_int = ip_to_int(netmask)

    Bitwise.band(ip_int, netmask_int) == subnet_int
  end

  defp ip_to_int({a, b, c, d}),
    do: Bitwise.bsl(a, 24) ||| Bitwise.bsl(b, 16) ||| Bitwise.bsl(c, 8) ||| d
end
