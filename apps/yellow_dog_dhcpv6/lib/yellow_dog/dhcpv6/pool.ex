defmodule YellowDog.Dhcpv6.Pool do
  @moduledoc """
  DHCPv6 address pool configuration structure.

  Represents a pool with prefix configuration, allocation ranges,
  static reservations, lifetimes, prefix delegation pools, and ACL rules.
  """

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
        "address" => format_ipv6(prefix_ip),
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
    |> maybe_put_list("dns_servers", Enum.map(pool.dns_servers, &format_ipv6/1))
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

  defp get_value(config, key, default \\ nil) do
    atom_key = if is_atom(key), do: key, else: String.to_existing_atom("#{key}")
    string_key = if is_binary(key), do: key, else: Atom.to_string(key)

    Map.get(config, atom_key) ||
      Map.get(config, string_key) ||
      default
  rescue
    ArgumentError -> Map.get(config, key, default)
  end

  defp parse_prefix(config) do
    case get_value(config, :prefix) do
      %{"address" => addr, "prefix_len" => prefix} ->
        case parse_ipv6(addr) do
          nil -> {:error, "Invalid prefix address"}
          ip -> {:ok, {ip, prefix}}
        end

      %{address: addr, prefix_len: prefix} ->
        case parse_ipv6(addr) do
          nil -> {:error, "Invalid prefix address"}
          ip -> {:ok, {ip, prefix}}
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
      %{"start" => start_str, "end" => end_str} ->
        parse_range_pair(start_str, end_str)

      %{start: start_str, end: end_str} ->
        parse_range_pair(start_str, end_str)

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

  defp parse_ipv6(nil), do: nil
  defp parse_ipv6(ip) when is_tuple(ip) and tuple_size(ip) == 8, do: ip

  defp parse_ipv6(ip) when is_binary(ip) do
    case :inet.parse_ipv6_address(String.to_charlist(ip)) do
      {:ok, addr} -> addr
      {:error, _} -> nil
    end
  end

  defp parse_ipv6(_), do: nil

  defp parse_ipv6_list(nil), do: []

  defp parse_ipv6_list(list) when is_list(list) do
    list |> Enum.map(&parse_ipv6/1) |> Enum.reject(&is_nil/1)
  end

  defp parse_ipv6_list(_), do: []

  defp parse_mode(:slaac), do: :slaac
  defp parse_mode(:stateful), do: :stateful
  defp parse_mode(:stateless), do: :stateless
  defp parse_mode("slaac"), do: :slaac
  defp parse_mode("stateful"), do: :stateful
  defp parse_mode("stateless"), do: :stateless
  defp parse_mode(_), do: :stateful

  defp parse_lifetimes(config) do
    case get_value(config, :lifetimes) do
      %{"preferred" => pref, "valid" => valid} ->
        %{preferred: pref, valid: valid}

      %{preferred: pref, valid: valid} ->
        %{preferred: pref, valid: valid}

      _ ->
        # Try legacy field names
        pref = get_value(config, :preferred_lifetime, 3600)
        valid = get_value(config, :valid_lifetime, 7200)
        %{preferred: pref, valid: valid}
    end
  end

  defp parse_reservations(nil), do: %{}

  defp parse_reservations(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {duid, ip}, acc ->
      parsed_ip = parse_ipv6(ip)
      if parsed_ip, do: Map.put(acc, normalize_duid(duid), parsed_ip), else: acc
    end)
  end

  defp parse_reservations(_), do: %{}

  defp parse_pd_pools(nil), do: []

  defp parse_pd_pools(pools) when is_list(pools) do
    Enum.map(pools, &parse_pd_pool/1) |> Enum.reject(&is_nil/1)
  end

  defp parse_pd_pools(_), do: []

  defp parse_pd_pool(%{"prefix" => prefix, "length" => len, "delegated_len" => del_len}) do
    case parse_ipv6(prefix) do
      nil -> nil
      ip -> %{prefix: ip, length: len, delegated_len: del_len}
    end
  end

  defp parse_pd_pool(%{prefix: prefix, length: len, delegated_len: del_len}) do
    case parse_ipv6(prefix) do
      nil -> nil
      ip -> %{prefix: ip, length: len, delegated_len: del_len}
    end
  end

  defp parse_pd_pool(_), do: nil

  defp parse_options(nil), do: %{}

  defp parse_options(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {code, value}, acc ->
      code_int = if is_integer(code), do: code, else: String.to_integer("#{code}")
      Map.put(acc, code_int, value)
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
    rules |> Enum.map(&parse_acl_rule/1) |> Enum.reject(&is_nil/1)
  end

  defp parse_acl_rules(_), do: []

  defp parse_acl_rule(%{"type" => "duid", "pattern" => pattern}), do: {:duid, pattern}
  defp parse_acl_rule(%{type: "duid", pattern: pattern}), do: {:duid, pattern}

  defp parse_acl_rule(%{"type" => "option", "code" => code, "value" => value}),
    do: {:option, code, value}

  defp parse_acl_rule(%{type: "option", code: code, value: value}), do: {:option, code, value}
  defp parse_acl_rule(%{"type" => "vendor_class", "value" => value}), do: {:vendor_class, value}
  defp parse_acl_rule(%{type: "vendor_class", value: value}), do: {:vendor_class, value}
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

  defp format_ipv6(addr) when is_tuple(addr) and tuple_size(addr) == 8 do
    addr
    |> Tuple.to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
    |> String.downcase()
  end

  defp format_ipv6(ip) when is_binary(ip), do: ip
  defp format_ipv6(nil), do: nil

  defp format_reservations(map) when map == %{}, do: nil

  defp format_reservations(map) do
    Enum.reduce(map, %{}, fn {duid, ip}, acc ->
      Map.put(acc, duid, format_ipv6(ip))
    end)
  end

  defp format_pd_pools([]), do: nil

  defp format_pd_pools(pools) do
    Enum.map(pools, fn %{prefix: prefix, length: len, delegated_len: del_len} ->
      %{"prefix" => format_ipv6(prefix), "length" => len, "delegated_len" => del_len}
    end)
  end

  defp format_options(map) when map == %{}, do: nil
  defp format_options(map), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_range(map, _key, nil), do: map

  defp maybe_put_range(map, key, {start_ip, end_ip}) do
    Map.put(map, key, %{"start" => format_ipv6(start_ip), "end" => format_ipv6(end_ip)})
  end

  defp maybe_put_list(map, _key, []), do: map
  defp maybe_put_list(map, key, list), do: Map.put(map, key, list)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, _key, m) when map_size(m) == 0, do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

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
