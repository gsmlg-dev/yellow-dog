defmodule YellowDog.Dhcpv6.Pool do
  @moduledoc """
  DHCPv6 address pool configuration structure.

  Represents a pool with prefix configuration, allocation ranges,
  static reservations, lifetimes, prefix delegation pools, and ACL rules.
  """

  import YellowDog.ConfigHelpers

  alias YellowDog.Dhcpv6.Ipv6Util

  @type ipv6_address ::
          {0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535}
  @type duid :: binary()
  @type option_code :: 1..65535
  @type duid_pattern :: String.t()
  @type mode :: :slaac | :stateful | :stateless

  @type acl_rule ::
          {:duid, duid_pattern()}
          | {:option, option_code(), binary()}
          | {:vendor_class, String.t()}

  @type acl_config :: %{
          allow: [acl_rule()],
          deny: [acl_rule()]
        }

  @type pd_pool :: %{
          prefix: ipv6_address(),
          length: 48..64,
          delegated_len: 48..64
        }

  @type t :: %__MODULE__{
          name: String.t(),
          prefix: {ipv6_address(), prefix_len :: 0..128},
          mode: mode(),
          range: {ipv6_address(), ipv6_address()} | nil,
          dns_servers: [ipv6_address()],
          domain_name: String.t() | nil,
          lifetimes: %{preferred: pos_integer(), valid: pos_integer()},
          max_leases: pos_integer(),
          reservations: %{String.t() => ipv6_address()},
          pd_pools: [pd_pool()],
          options: %{option_code() => binary() | String.t()},
          acl: acl_config(),
          enabled: boolean()
        }

  defstruct [
    :name,
    :prefix,
    :range,
    mode: :stateful,
    dns_servers: [],
    domain_name: nil,
    lifetimes: %{preferred: 3600, valid: 7200},
    max_leases: 1000,
    reservations: %{},
    pd_pools: [],
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
         {:ok, prefix} <- parse_prefix(config),
         {:ok, range} <- parse_range(config, prefix) do
      pool = %__MODULE__{
        name: name,
        prefix: prefix,
        mode: parse_mode(get_value(config, :mode, :stateful)),
        range: range,
        dns_servers: parse_ipv6_list(get_value(config, :dns_servers, [])),
        domain_name: get_value(config, :domain_name),
        lifetimes: parse_lifetimes(config),
        max_leases: get_value(config, :max_leases, 1000),
        reservations: parse_reservations(get_value(config, :reservations, %{})),
        pd_pools: parse_pd_pools(get_value(config, :pd_pools, [])),
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
    {prefix_ip, prefix_len} = pool.prefix

    base = %{
      "name" => pool.name,
      "enabled" => pool.enabled,
      "mode" => Atom.to_string(pool.mode),
      "prefix" => %{
        "address" => Ipv6Util.format(prefix_ip),
        "prefix_len" => prefix_len
      },
      "lifetimes" => %{
        "preferred" => pool.lifetimes.preferred,
        "valid" => pool.lifetimes.valid
      },
      "max_leases" => pool.max_leases
    }

    base
    |> maybe_put_range("range", pool.range)
    |> maybe_put("domain_name", pool.domain_name)
    |> maybe_put_list("dns_servers", Enum.map(pool.dns_servers, &Ipv6Util.format/1))
    |> maybe_put_map("reservations", format_reservations(pool.reservations))
    |> maybe_put_list("pd_pools", format_pd_pools(pool.pd_pools))
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
         :ok <- validate_prefix(pool.prefix),
         :ok <- validate_range(pool.range, pool.prefix),
         :ok <- validate_lifetimes(pool.lifetimes) do
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

  defp parse_prefix(config) do
    case get_value(config, :prefix) do
      map when is_map(map) ->
        case {get_value(map, :address), get_value(map, :prefix_len)} do
          {nil, _} ->
            {:error, "Invalid prefix address"}

          {_, nil} ->
            {:error, "Missing prefix length"}

          {addr, prefix} ->
            case parse_ipv6(addr) do
              nil -> {:error, "Invalid prefix address"}
              ip -> {:ok, {ip, prefix}}
            end
        end

      cidr when is_binary(cidr) ->
        parse_cidr(cidr)

      nil ->
        # Try network field (legacy)
        case get_value(config, :network) do
          nil -> {:error, "Missing prefix configuration"}
          cidr -> parse_cidr(cidr)
        end

      _ ->
        {:error, "Invalid prefix format"}
    end
  end

  defp parse_cidr(cidr) when is_binary(cidr) do
    case String.split(cidr, "/") do
      [addr, prefix_str] ->
        case {parse_ipv6(addr), Integer.parse(prefix_str)} do
          {nil, _} -> {:error, "Invalid IPv6 in CIDR"}
          {_, :error} -> {:error, "Invalid prefix length in CIDR"}
          {ip, {prefix, ""}} when prefix >= 0 and prefix <= 128 -> {:ok, {ip, prefix}}
          _ -> {:error, "Invalid CIDR format"}
        end

      _ ->
        {:error, "Invalid CIDR format"}
    end
  end

  defp parse_range(config, _prefix) do
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
          # Range is optional for SLAAC mode
          {:ok, nil}
        end

      _ ->
        {:error, "Invalid range format"}
    end
  end

  defp parse_range_pair(start_val, end_val) do
    start_ip = parse_ipv6(start_val)
    end_ip = parse_ipv6(end_val)

    cond do
      is_nil(start_ip) -> {:error, "Invalid range start IP"}
      is_nil(end_ip) -> {:error, "Invalid range end IP"}
      true -> {:ok, {start_ip, end_ip}}
    end
  end

  defp parse_ipv6(ip) do
    case Ipv6Util.parse(ip) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, _} -> nil
    end
  end

  defp parse_ipv6_list(nil), do: []

  defp parse_ipv6_list(list) when is_list(list) do
    for(item <- list, ip = parse_ipv6(item), ip != nil, do: ip)
  end

  defp parse_ipv6_list(_), do: []

  @valid_modes %{
    "slaac" => :slaac,
    "stateful" => :stateful,
    "stateless" => :stateless,
    slaac: :slaac,
    stateful: :stateful,
    stateless: :stateless
  }

  defp parse_mode(mode), do: Map.get(@valid_modes, mode, :stateful)

  defp parse_lifetimes(config) do
    case get_value(config, :lifetimes) do
      map when is_map(map) ->
        %{
          preferred: get_value(map, :preferred, 3600),
          valid: get_value(map, :valid, 7200)
        }

      _ ->
        # Try legacy field names
        pref = get_value(config, :preferred_lifetime, 3600)
        valid = get_value(config, :valid_lifetime, 7200)
        %{preferred: pref, valid: valid}
    end
  end

  defp parse_reservations(nil), do: %{}

  defp parse_reservations(map) when is_map(map) do
    for {duid, ip} <- map, parsed_ip = parse_ipv6(ip), parsed_ip != nil, into: %{} do
      {normalize_duid(duid), parsed_ip}
    end
  end

  defp parse_reservations(_), do: %{}

  defp parse_pd_pools(nil), do: []

  defp parse_pd_pools(pools) when is_list(pools) do
    for(pool <- pools, parsed = parse_pd_pool(pool), parsed != nil, do: parsed)
  end

  defp parse_pd_pools(_), do: []

  defp parse_pd_pool(map) when is_map(map) do
    with prefix when not is_nil(prefix) <- get_value(map, :prefix),
         len when not is_nil(len) <- get_value(map, :length),
         del_len when not is_nil(del_len) <- get_value(map, :delegated_len),
         ip when not is_nil(ip) <- parse_ipv6(prefix) do
      %{prefix: ip, length: len, delegated_len: del_len}
    else
      _ -> nil
    end
  end

  defp parse_pd_pool(_), do: nil

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
      "duid" -> {:duid, get_value(map, :pattern)}
      "option" -> {:option, get_value(map, :code), get_value(map, :value)}
      "vendor_class" -> {:vendor_class, get_value(map, :value)}
      _ -> nil
    end
  end

  defp parse_acl_rule(_), do: nil

  # Validation helpers

  defp validate_name(nil), do: {:error, "Pool name is required"}
  defp validate_name(""), do: {:error, "Pool name cannot be empty"}
  defp validate_name(name) when is_binary(name), do: :ok
  defp validate_name(_), do: {:error, "Pool name must be a string"}

  defp validate_prefix({ip, prefix}) when is_tuple(ip) and prefix >= 0 and prefix <= 128, do: :ok
  defp validate_prefix(_), do: {:error, "Invalid prefix"}

  defp validate_range(nil, _prefix), do: :ok

  defp validate_range({start_ip, end_ip}, _prefix)
       when is_tuple(start_ip) and is_tuple(end_ip),
       do: :ok

  defp validate_range(_, _), do: {:error, "Invalid range"}

  defp validate_lifetimes(%{preferred: pref, valid: valid}) when pref <= valid, do: :ok
  defp validate_lifetimes(_), do: {:error, "Preferred lifetime must be <= valid lifetime"}

  # Formatting helpers

  defp format_reservations(map) when map == %{}, do: nil

  defp format_reservations(map) do
    Map.new(map, fn {duid, ip} -> {duid, Ipv6Util.format(ip)} end)
  end

  defp format_pd_pools([]), do: []

  defp format_pd_pools(pools) do
    Enum.map(pools, fn %{prefix: prefix, length: len, delegated_len: del_len} ->
      %{"prefix" => Ipv6Util.format(prefix), "length" => len, "delegated_len" => del_len}
    end)
  end

  defp format_options(map) when map == %{}, do: nil
  defp format_options(map), do: map

  defp maybe_put_range(map, _key, nil), do: map

  defp maybe_put_range(map, key, {start_ip, end_ip}) do
    Map.put(map, key, %{"start" => Ipv6Util.format(start_ip), "end" => Ipv6Util.format(end_ip)})
  end

  defp maybe_put_acl(map, _key, %{allow: [], deny: []}), do: map
  defp maybe_put_acl(map, key, acl), do: Map.put(map, key, format_acl(acl))

  defp format_acl(%{allow: allow, deny: deny}) do
    %{
      "allow" => Enum.map(allow, &format_acl_rule/1),
      "deny" => Enum.map(deny, &format_acl_rule/1)
    }
  end

  defp format_acl_rule({:duid, pattern}), do: %{"type" => "duid", "pattern" => pattern}

  defp format_acl_rule({:option, code, value}),
    do: %{"type" => "option", "code" => code, "value" => value}

  defp format_acl_rule({:vendor_class, value}), do: %{"type" => "vendor_class", "value" => value}

  defp normalize_duid(duid) when is_binary(duid), do: String.upcase(duid)
  defp normalize_duid(duid), do: "#{duid}"
end
