defmodule YellowDog.Dns.View.ACL do
  @moduledoc """
  Access Control List (ACL) implementation for DNS views.

  ACLs define which clients can access specific DNS views based on
  their IP addresses or geographic location. An ACL consists of:
  - Name (identifier)
  - Rules (IP addresses, CIDR blocks, geographic locations, or named ACLs)
  - Match logic (allow/deny)

  ## Built-in ACLs

  - `"any"` - Matches all clients
  - `"none"` - Matches no clients
  - `"localhost"` - Matches 127.0.0.1 and ::1
  - `"localnets"` - Matches RFC 1918 private networks

  ## Rule Types

  ### IP/CIDR Rules
      {:allow, {10, 0, 0, 0}, 8}      # Allow 10.0.0.0/8
      {:deny, "192.168.1.0/24"}       # Deny 192.168.1.0/24

  ### Geo Rules
      {:allow, {:geo, ["US", "CA"]}}  # Allow from USA and Canada
      {:deny, {:geo, ["CN", "RU"]}}   # Deny from China and Russia

  ## Examples

      # Define an ACL for internal network
      iex> internal = ACL.new("internal", [
      ...>   {:allow, {10, 0, 0, 0}, 8},
      ...>   {:allow, {192, 168, 0, 0}, 16}
      ...> ])

      # Check if IP matches
      iex> ACL.matches?(internal, {10, 1, 2, 3})
      true

      iex> ACL.matches?(internal, {8, 8, 8, 8})
      false

      # Use CIDR notation
      iex> external = ACL.new("external", [
      ...>   {:allow, "203.0.113.0/24"},
      ...>   {:deny, "203.0.113.100/32"}
      ...> ])

      # Use geo-based rules
      iex> north_america = ACL.new("north_america", [
      ...>   {:allow, {:geo, ["US", "CA", "MX"]}}
      ...> ])
  """

  defstruct [:name, :rules]

  @valid_actions [:allow, :deny]

  @type ip_address :: :inet.ip_address()
  @type cidr :: {ip_address(), non_neg_integer()}
  @type geo_rule :: {:geo, [String.t()]}
  @type rule ::
          {:allow, ip_address() | cidr() | String.t() | geo_rule()}
          | {:deny, ip_address() | cidr() | String.t() | geo_rule()}
          | {:allow, ip_address(), non_neg_integer()}
          | {:deny, ip_address(), non_neg_integer()}
  @type t :: %__MODULE__{
          name: String.t(),
          rules: [rule()]
        }

  # Built-in ACL definitions
  @builtin_acls %{
    "any" => [{:allow, :any}],
    "none" => [{:deny, :any}],
    "localhost" => [
      {:allow, {127, 0, 0, 1}, 32},
      {:allow, {0, 0, 0, 0, 0, 0, 0, 1}, 128}
    ],
    "localnets" => [
      {:allow, {10, 0, 0, 0}, 8},
      {:allow, {172, 16, 0, 0}, 12},
      {:allow, {192, 168, 0, 0}, 16}
    ]
  }

  @doc """
  Creates a new ACL with the given name and rules.

  ## Parameters
  - `name` - ACL identifier
  - `rules` - List of rules (allow/deny with IP/CIDR)

  ## Examples

      iex> ACL.new("internal", [{:allow, {10, 0, 0, 0}, 8}])
      %ACL{name: "internal", rules: [{:allow, {10, 0, 0, 0}, 8}]}
  """
  @spec new(String.t(), [rule()]) :: t()
  def new(name, rules) when is_binary(name) and is_list(rules) do
    %__MODULE__{
      name: name,
      rules: rules
    }
  end

  @doc """
  Checks if an IP address matches the ACL.

  Rules are evaluated in order. The first matching rule determines
  the result. If no rules match, the default is deny (false).

  ## Parameters
  - `acl` - The ACL to check against
  - `ip` - Client IP address tuple

  ## Returns
  - `true` if IP matches (allowed)
  - `false` if IP doesn't match (denied)

  ## Examples

      iex> acl = ACL.new("test", [{:allow, {10, 0, 0, 0}, 8}])
      iex> ACL.matches?(acl, {10, 1, 2, 3})
      true

      iex> ACL.matches?(acl, {192, 168, 1, 1})
      false
  """
  @spec matches?(t() | String.t(), ip_address()) :: boolean()
  def matches?(%__MODULE__{rules: rules}, ip) do
    evaluate_rules(rules, ip)
  end

  def matches?(acl_name, ip) when is_binary(acl_name) do
    # Check for built-in ACLs
    case Map.get(@builtin_acls, acl_name) do
      nil ->
        # Unknown ACL, default deny
        false

      rules ->
        evaluate_rules(rules, ip)
    end
  end

  @doc """
  Gets a built-in ACL by name.

  ## Parameters
  - `name` - Built-in ACL name ("any", "none", "localhost", "localnets")

  ## Returns
  - `{:ok, acl}` if found
  - `{:error, :not_found}` if not found

  ## Examples

      iex> {:ok, acl} = ACL.get_builtin("localhost")
      iex> ACL.matches?(acl, {127, 0, 0, 1})
      true
  """
  @spec get_builtin(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_builtin(name) when is_binary(name) do
    case Map.get(@builtin_acls, name) do
      nil -> {:error, :not_found}
      rules -> {:ok, new(name, rules)}
    end
  end

  @doc """
  Lists all available built-in ACL names.

  ## Examples

      iex> ACL.list_builtins()
      ["any", "localhost", "localnets", "none"]
  """
  @spec list_builtins() :: [String.t()]
  def list_builtins do
    Map.keys(@builtin_acls) |> Enum.sort()
  end

  @doc """
  Parses a CIDR notation string to IP and prefix length.

  ## Examples

      iex> ACL.parse_cidr("192.168.1.0/24")
      {:ok, {{192, 168, 1, 0}, 24}}

      iex> ACL.parse_cidr("2001:db8::/32")
      {:ok, {{0x2001, 0xdb8, 0, 0, 0, 0, 0, 0}, 32}}

      iex> ACL.parse_cidr("invalid")
      {:error, :invalid_cidr}
  """
  @spec parse_cidr(String.t()) :: {:ok, cidr()} | {:error, :invalid_cidr}
  def parse_cidr(cidr_string) when is_binary(cidr_string) do
    case String.split(cidr_string, "/") do
      [ip_str, prefix_str] ->
        with {:ok, ip} <- parse_ip(ip_str),
             {prefix, ""} <- Integer.parse(prefix_str),
             true <- valid_prefix_length?(ip, prefix) do
          {:ok, {ip, prefix}}
        else
          _ -> {:error, :invalid_cidr}
        end

      _ ->
        {:error, :invalid_cidr}
    end
  end

  # Private Functions

  defp evaluate_rules([], _ip), do: false

  defp evaluate_rules([rule | rest], ip) do
    case match_rule?(rule, ip) do
      {:match, :allow} -> true
      {:match, :deny} -> false
      :no_match -> evaluate_rules(rest, ip)
    end
  end

  defp match_rule?({action, :any}, _ip) when action in @valid_actions do
    {:match, action}
  end

  defp match_rule?({action, ip, prefix}, client_ip) when action in @valid_actions do
    if ip_in_subnet?(client_ip, ip, prefix) do
      {:match, action}
    else
      :no_match
    end
  end

  defp match_rule?({action, ip}, client_ip) when action in @valid_actions and is_tuple(ip) do
    # Exact IP match
    if client_ip == ip do
      {:match, action}
    else
      :no_match
    end
  end

  defp match_rule?({action, cidr_string}, client_ip)
       when action in @valid_actions and is_binary(cidr_string) do
    case parse_cidr(cidr_string) do
      {:ok, {ip, prefix}} ->
        if ip_in_subnet?(client_ip, ip, prefix) do
          {:match, action}
        else
          :no_match
        end

      {:error, _} ->
        :no_match
    end
  end

  # Geo-based rule matching
  # Matches clients based on their geographic location (country)
  defp match_rule?({action, {:geo, country_codes}}, client_ip)
       when action in @valid_actions and is_list(country_codes) do
    case GeoIpDb.country_code(client_ip) do
      {:ok, code} when is_binary(code) ->
        if code in country_codes do
          {:match, action}
        else
          :no_match
        end

      # IP not found in geo database, no match
      _ ->
        :no_match
    end
  end

  defp match_rule?(_, _), do: :no_match

  defp ip_in_subnet?(client_ip, network_ip, prefix_length)
       when tuple_size(client_ip) == 4 and tuple_size(network_ip) == 4 do
    # IPv4 subnet check
    client_bits = ip_to_binary(client_ip)
    network_bits = ip_to_binary(network_ip)

    <<client_prefix::size(prefix_length), _::bitstring>> = client_bits
    <<network_prefix::size(prefix_length), _::bitstring>> = network_bits

    client_prefix == network_prefix
  end

  defp ip_in_subnet?(client_ip, network_ip, prefix_length)
       when tuple_size(client_ip) == 8 and tuple_size(network_ip) == 8 do
    # IPv6 subnet check
    client_bits = ipv6_to_binary(client_ip)
    network_bits = ipv6_to_binary(network_ip)

    <<client_prefix::size(prefix_length), _::bitstring>> = client_bits
    <<network_prefix::size(prefix_length), _::bitstring>> = network_bits

    client_prefix == network_prefix
  end

  defp ip_in_subnet?(_, _, _), do: false

  defp ip_to_binary({a, b, c, d}) do
    <<a, b, c, d>>
  end

  defp ipv6_to_binary({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, _ip} = ok -> ok
      {:error, _} -> {:error, :invalid_ip}
    end
  end

  defp valid_prefix_length?(ip, prefix) when tuple_size(ip) == 4 do
    prefix >= 0 and prefix <= 32
  end

  defp valid_prefix_length?(ip, prefix) when tuple_size(ip) == 8 do
    prefix >= 0 and prefix <= 128
  end

  defp valid_prefix_length?(_, _), do: false
end
