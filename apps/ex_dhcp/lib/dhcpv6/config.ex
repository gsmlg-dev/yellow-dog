defmodule DHCPv6.Config do
  @moduledoc """
  DHCPv6 Server configuration schema and validation according to RFC 3315.

  Provides structured configuration for DHCPv6 server with validation
  and sensible defaults.
  """

  @type t :: %__MODULE__{
          prefix: :inet.ip6_address(),
          prefix_length: integer(),
          range_start: :inet.ip6_address(),
          range_end: :inet.ip6_address(),
          dns_servers: [:inet.ip6_address()],
          lease_time: integer(),
          rapid_commit: boolean(),
          options: [DHCPv6.Message.Option.t()]
        }

  defstruct [
    :prefix,
    :prefix_length,
    :range_start,
    :range_end,
    dns_servers: [],
    lease_time: 3600,
    rapid_commit: false,
    options: []
  ]

  @doc """
  Create a new DHCPv6 configuration from keyword options.

  ## Options

    * `:prefix` - IPv6 prefix address (required)
    * `:prefix_length` - Prefix length (required)
    * `:range_start` - Start of IPv6 range (required)
    * `:range_end` - End of IPv6 range (required)
    * `:dns_servers` - List of DNS servers (default: [])
    * `:lease_time` - Lease duration in seconds (default: 3600)
    * `:rapid_commit` - Enable rapid commit (default: false)
    * `:options` - Additional DHCPv6 options (default: [])

  ## Examples

      iex> config = DHCPv6.Config.new(
      ...>   prefix: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000},
      ...>   prefix_length: 64,
      ...>   range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0001},
      ...>   range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xFFFF},
      ...>   dns_servers: [{0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}],
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
  Create a new DHCPv6 configuration from keyword options, raising on errors.
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
      not is_valid_ipv6(config.prefix) ->
        {:error, "Invalid IPv6 prefix"}

      config.prefix_length < 0 or config.prefix_length > 128 ->
        {:error, "Invalid prefix length (0-128)"}

      not is_valid_ipv6(config.range_start) ->
        {:error, "Invalid range_start address"}

      not is_valid_ipv6(config.range_end) ->
        {:error, "Invalid range_end address"}

      not in_prefix?(config.range_start, config.prefix, config.prefix_length) ->
        {:error, "range_start not in prefix"}

      not in_prefix?(config.range_end, config.prefix, config.prefix_length) ->
        {:error, "range_end not in prefix"}

      ip6_to_int(config.range_start) > ip6_to_int(config.range_end) ->
        {:error, "range_start must be before range_end"}

      Enum.any?(config.dns_servers, &(not is_valid_ipv6(&1))) ->
        {:error, "Invalid DNS server address"}

      config.lease_time < 60 ->
        {:error, "lease_time must be at least 60 seconds"}

      true ->
        :ok
    end
  end

  defp is_valid_ipv6({a, b, c, d, e, f, g, h})
       when a in 0x0..0xFFFF and b in 0x0..0xFFFF and c in 0x0..0xFFFF and d in 0x0..0xFFFF and
              e in 0x0..0xFFFF and f in 0x0..0xFFFF and g in 0x0..0xFFFF and h in 0x0..0xFFFF,
       do: true

  defp is_valid_ipv6(_), do: false

  defp in_prefix?(ip, prefix, prefix_len) do
    ip_int = ip6_to_int(ip)
    prefix_int = ip6_to_int(prefix)

    mask =
      if prefix_len > 0, do: trunc(:math.pow(2, 128) - :math.pow(2, 128 - prefix_len)), else: 0

    Bitwise.band(ip_int, mask) == Bitwise.band(prefix_int, mask)
  end

  defp ip6_to_int({a, b, c, d, e, f, g, h}) do
    Bitwise.bor(
      Bitwise.bsl(a, 112),
      Bitwise.bor(
        Bitwise.bsl(b, 96),
        Bitwise.bor(
          Bitwise.bsl(c, 80),
          Bitwise.bor(
            Bitwise.bsl(d, 64),
            Bitwise.bor(
              Bitwise.bsl(e, 48),
              Bitwise.bor(
                Bitwise.bsl(f, 32),
                Bitwise.bor(Bitwise.bsl(g, 16), h)
              )
            )
          )
        )
      )
    )
  end
end
