defmodule YellowDog.Dhcpv4.Pool do
  @moduledoc """
  DHCPv4 address pool configuration structure.

  Represents a pool with subnet configuration, allocation ranges,
  static reservations, lease times, and ACL rules.
  """

  alias YellowDog.Dhcpv4.Ipv4Util

  import Bitwise
  import YellowDog.ConfigHelpers

  @type ip_address :: {0..255, 0..255, 0..255, 0..255}
  @type mac_address :: <<_::48>> | String.t()
  @type option_code :: 1..254
  @type mac_pattern :: String.t()

  @type acl_rule ::
          {:mac, mac_pattern()}
          | {:option, option_code(), binary()}
          | {:vendor_class, String.t()}
          | {:user_class, String.t()}

  @type acl_config :: %{
          allow: [acl_rule()],
          deny: [acl_rule()]
        }

  @type t :: %__MODULE__{
          name: String.t(),
          subnet: {ip_address(), prefix_len :: 0..32},
          range: {ip_address(), ip_address()},
          gateway: ip_address() | nil,
          dns_servers: [ip_address()],
          domain_name: String.t() | nil,
          lease_time: %{default: pos_integer(), max: pos_integer()},
          max_leases: pos_integer(),
          reservations: %{String.t() => ip_address()},
          options: %{option_code() => binary() | String.t()},
          acl: acl_config(),
          enabled: boolean()
        }

  defstruct [
    :name,
    :subnet,
    :range,
    :gateway,
    dns_servers: [],
    domain_name: nil,
    lease_time: %{default: 3600, max: 86400},
    max_leases: 1000,
    reservations: %{},
    options: %{},
    acl: %{allow: [], deny: []},
    enabled: true
  ]

  @doc """
  Creates a new Pool from a configuration map.

  ## Parameters
  - `config` - Map with pool configuration

  ## Returns
  - `{:ok, pool}` on success
  - `{:error, reason}` on validation failure
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(config) when is_map(config) do
    with {:ok, name} <- get_required(config, :name),
         {:ok, subnet} <- parse_subnet(config),
         {:ok, range} <- parse_range(config),
         :ok <- validate_range_in_subnet(range, subnet) do
      pool = %__MODULE__{
        name: name,
        subnet: subnet,
        range: range,
        gateway: parse_ip(get_value(config, :gateway)),
        dns_servers: parse_ip_list(get_value(config, :dns_servers, [])),
        domain_name: get_value(config, :domain_name),
        lease_time: parse_lease_time(config),
        max_leases: get_value(config, :max_leases, 1000),
        reservations: parse_reservations(get_value(config, :reservations, %{})),
        options: parse_options(get_value(config, :options, %{})),
        acl: parse_acl(get_value(config, :acl, %{})),
        enabled: get_value(config, :enabled, true)
      }

      {:ok, pool}
    end
  end

  @doc """
  Converts a Pool struct to a TOML-serializable map.
  """
  @spec to_toml_map(t()) :: map()
  def to_toml_map(%__MODULE__{} = pool) do
    {subnet_ip, prefix_len} = pool.subnet
    {range_start, range_end} = pool.range

    base = %{
      "name" => pool.name,
      "enabled" => pool.enabled,
      "subnet" => %{
        "address" => Ipv4Util.format(subnet_ip),
        "prefix_len" => prefix_len
      },
      "range" => %{
        "start" => Ipv4Util.format(range_start),
        "end" => Ipv4Util.format(range_end)
      },
      "lease_time" => %{
        "default" => pool.lease_time.default,
        "max" => pool.lease_time.max
      },
      "max_leases" => pool.max_leases
    }

    base
    |> maybe_put("gateway", Ipv4Util.format(pool.gateway))
    |> maybe_put("domain_name", pool.domain_name)
    |> maybe_put_list("dns_servers", Enum.map(pool.dns_servers, &Ipv4Util.format/1))
    |> maybe_put_map("reservations", format_reservations(pool.reservations))
    |> maybe_put_map("options", format_options(pool.options))
    |> maybe_put_acl("acl", pool.acl)
  end

  @doc """
  Validates a Pool struct.

  ## Returns
  - `:ok` if valid
  - `{:error, reason}` if invalid
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = pool) do
    with :ok <- validate_name(pool.name),
         :ok <- validate_subnet(pool.subnet),
         :ok <- validate_range(pool.range),
         :ok <- validate_range_in_subnet(pool.range, pool.subnet),
         :ok <- validate_reservations(pool.reservations, pool.subnet) do
      :ok
    end
  end

  # Parsing helpers

  defp get_required(config, key) do
    case get_value(config, key) do
      nil -> {:error, "Missing required field: #{key}"}
      value -> {:ok, value}
    end
  end

  defp parse_subnet(config) do
    case get_value(config, :subnet) do
      map when is_map(map) ->
        case {get_value(map, :address), get_value(map, :prefix_len)} do
          {nil, _} -> {:error, "Invalid subnet address"}
          {_, nil} -> {:error, "Missing prefix length"}
          {addr, prefix} ->
            case parse_ip(addr) do
              nil -> {:error, "Invalid subnet address"}
              ip -> {:ok, {ip, prefix}}
            end
        end

      cidr when is_binary(cidr) ->
        parse_cidr(cidr)

      nil ->
        # Try network field (legacy)
        case get_value(config, :network) do
          nil -> {:error, "Missing subnet configuration"}
          cidr -> parse_cidr(cidr)
        end

      _ ->
        {:error, "Invalid subnet format"}
    end
  end

  defp parse_cidr(cidr) when is_binary(cidr) do
    case String.split(cidr, "/") do
      [addr, prefix_str] ->
        case {parse_ip(addr), Integer.parse(prefix_str)} do
          {nil, _} -> {:error, "Invalid IP in CIDR"}
          {_, :error} -> {:error, "Invalid prefix in CIDR"}
          {ip, {prefix, ""}} when prefix >= 0 and prefix <= 32 -> {:ok, {ip, prefix}}
          _ -> {:error, "Invalid CIDR format"}
        end

      _ ->
        {:error, "Invalid CIDR format"}
    end
  end

  defp parse_range(config) do
    case get_value(config, :range) do
      map when is_map(map) ->
        parse_range_pair(get_value(map, :start), get_value(map, :end))

      nil ->
        # Try legacy range_start/range_end
        start_val = get_value(config, :range_start)
        end_val = get_value(config, :range_end)

        if start_val && end_val do
          parse_range_pair(start_val, end_val)
        else
          {:error, "Missing range configuration"}
        end

      _ ->
        {:error, "Invalid range format"}
    end
  end

  defp parse_range_pair(start_val, end_val) do
    start_ip = parse_ip(start_val)
    end_ip = parse_ip(end_val)

    cond do
      is_nil(start_ip) ->
        {:error, "Invalid range start IP"}

      is_nil(end_ip) ->
        {:error, "Invalid range end IP"}

      Ipv4Util.to_integer(start_ip) > Ipv4Util.to_integer(end_ip) ->
        {:error, "Range start must be <= range end"}

      true ->
        {:ok, {start_ip, end_ip}}
    end
  end

  defp parse_ip(ip) do
    case Ipv4Util.parse(ip) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, _} -> nil
    end
  end

  defp parse_ip_list(nil), do: []

  defp parse_ip_list(list) when is_list(list),
    do: for(item <- list, ip = parse_ip(item), ip != nil, do: ip)

  defp parse_ip_list(_), do: []

  defp parse_lease_time(config) do
    case get_value(config, :lease_time) do
      map when is_map(map) ->
        %{default: get_value(map, :default, 3600), max: get_value(map, :max, 86400)}

      seconds when is_integer(seconds) ->
        %{default: seconds, max: seconds * 2}

      _ ->
        %{default: 3600, max: 86400}
    end
  end

  defp parse_reservations(nil), do: %{}

  defp parse_reservations(map) when is_map(map) do
    for {mac, ip} <- map, parsed_ip = parse_ip(ip), parsed_ip != nil, into: %{} do
      {normalize_mac(mac), parsed_ip}
    end
  end

  defp parse_reservations(_), do: %{}

  defp parse_options(nil), do: %{}

  defp parse_options(map) when is_map(map) do
    Map.new(map, fn {code, value} ->
      code_int = parse_option_code(code)
      {code_int, value}
    end)
  end

  defp parse_options(_), do: %{}

  defp parse_acl(nil), do: %{allow: [], deny: []}

  defp parse_acl(%{} = acl) do
    allow = parse_acl_rules(get_value(acl, :allow, []))
    deny = parse_acl_rules(get_value(acl, :deny, []))
    %{allow: allow, deny: deny}
  end

  defp parse_acl(_), do: %{allow: [], deny: []}

  defp parse_acl_rules(nil), do: []

  defp parse_acl_rules(rules) when is_list(rules) do
    for(rule <- rules, parsed = parse_acl_rule(rule), parsed != nil, do: parsed)
  end

  defp parse_acl_rules(_), do: []

  defp parse_acl_rule(map) when is_map(map) do
    case get_value(map, :type) do
      "mac" -> {:mac, get_value(map, :pattern)}
      "option" -> {:option, get_value(map, :code), get_value(map, :value)}
      "vendor_class" -> {:vendor_class, get_value(map, :value)}
      "user_class" -> {:user_class, get_value(map, :value)}
      _ -> nil
    end
  end

  defp parse_acl_rule(_), do: nil

  # Validation helpers

  defp validate_name(nil), do: {:error, "Pool name is required"}
  defp validate_name(""), do: {:error, "Pool name cannot be empty"}
  defp validate_name(name) when is_binary(name), do: :ok
  defp validate_name(_), do: {:error, "Pool name must be a string"}

  defp validate_subnet({ip, prefix}) when is_tuple(ip) and prefix >= 0 and prefix <= 32, do: :ok
  defp validate_subnet(_), do: {:error, "Invalid subnet"}

  defp validate_range({start_ip, end_ip}) when is_tuple(start_ip) and is_tuple(end_ip) do
    if Ipv4Util.to_integer(start_ip) <= Ipv4Util.to_integer(end_ip),
      do: :ok,
      else: {:error, "Invalid range"}
  end

  defp validate_range(_), do: {:error, "Invalid range"}

  defp validate_range_in_subnet({start_ip, end_ip}, {subnet_ip, prefix}) do
    mask = (1 <<< (32 - prefix)) - 1
    subnet_int = Ipv4Util.to_integer(subnet_ip) &&& ~~~mask
    start_int = Ipv4Util.to_integer(start_ip)
    end_int = Ipv4Util.to_integer(end_ip)

    network_end = subnet_int ||| mask

    if start_int >= subnet_int and end_int <= network_end do
      :ok
    else
      {:error, "Range must be within subnet"}
    end
  end

  defp validate_reservations(reservations, {subnet_ip, prefix}) do
    mask = (1 <<< (32 - prefix)) - 1
    subnet_int = Ipv4Util.to_integer(subnet_ip) &&& ~~~mask
    network_end = subnet_int ||| mask

    invalid =
      Enum.find(reservations, fn {_mac, ip} ->
        ip_int = Ipv4Util.to_integer(ip)
        ip_int < subnet_int or ip_int > network_end
      end)

    if invalid, do: {:error, "Reservation #{inspect(invalid)} outside subnet"}, else: :ok
  end

  defp format_reservations(map) when map == %{}, do: nil

  defp format_reservations(map) do
    Map.new(map, fn {mac, ip} -> {mac, Ipv4Util.format(ip)} end)
  end

  defp format_options(map) when map == %{}, do: nil
  defp format_options(map), do: map

  defp maybe_put_acl(map, _key, %{allow: [], deny: []}), do: map
  defp maybe_put_acl(map, key, acl), do: Map.put(map, key, format_acl(acl))

  defp format_acl(%{allow: allow, deny: deny}) do
    %{
      "allow" => Enum.map(allow, &format_acl_rule/1),
      "deny" => Enum.map(deny, &format_acl_rule/1)
    }
  end

  defp format_acl_rule({:mac, pattern}), do: %{"type" => "mac", "pattern" => pattern}

  defp format_acl_rule({:option, code, value}),
    do: %{"type" => "option", "code" => code, "value" => value}

  defp format_acl_rule({:vendor_class, value}), do: %{"type" => "vendor_class", "value" => value}
  defp format_acl_rule({:user_class, value}), do: %{"type" => "user_class", "value" => value}

  defp normalize_mac(mac) when is_binary(mac), do: String.upcase(mac)
  defp normalize_mac(mac), do: "#{mac}"
end
