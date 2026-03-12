defmodule YellowDog.Netman.Types.Profile do
  @moduledoc """
  Connection profile parsed from TOML configuration.
  """

  @type ipv4_method :: :auto | :manual | :disabled
  @type ipv6_method :: :auto | :manual | :disabled | :link_local
  @type connection_type :: :ethernet

  @type t :: %__MODULE__{
          id: String.t(),
          type: connection_type(),
          interface: String.t() | nil,
          autoconnect: boolean(),
          autoconnect_priority: integer(),
          zone: String.t(),
          ethernet: ethernet_config(),
          ipv4: ipv4_config(),
          ipv6: ipv6_config()
        }

  @type ethernet_config :: %{
          mtu: pos_integer() | nil
        }

  @type ipv4_config :: %{
          method: ipv4_method(),
          address: String.t() | nil,
          gateway: String.t() | nil,
          dns: [String.t()],
          dns_search: [String.t()]
        }

  @type ipv6_config :: %{
          method: ipv6_method(),
          address: String.t() | nil,
          gateway: String.t() | nil,
          dns: [String.t()],
          dns_search: [String.t()]
        }

  @enforce_keys [:id, :type]
  defstruct [
    :id,
    :type,
    :interface,
    autoconnect: true,
    autoconnect_priority: 0,
    zone: "default",
    ethernet: %{mtu: nil},
    ipv4: %{method: :auto, address: nil, gateway: nil, dns: [], dns_search: []},
    ipv6: %{method: :auto, address: nil, gateway: nil, dns: [], dns_search: []}
  ]

  @valid_ipv4_methods ~w(auto manual disabled)
  @valid_ipv6_methods ~w(auto manual disabled link-local)
  @valid_types ~w(ethernet)

  @doc "Parses a TOML map into a Profile struct."
  @spec from_toml(map()) :: {:ok, t()} | {:error, String.t()}
  def from_toml(toml) when is_map(toml) do
    with {:ok, connection} <- parse_connection(toml),
         {:ok, ethernet} <- parse_ethernet(toml),
         {:ok, ipv4} <- parse_ipv4(toml),
         {:ok, ipv6} <- parse_ipv6(toml) do
      {:ok,
       %__MODULE__{
         id: connection.id,
         type: connection.type,
         interface: connection.interface,
         autoconnect: connection.autoconnect,
         autoconnect_priority: connection.autoconnect_priority,
         zone: connection.zone,
         ethernet: ethernet,
         ipv4: ipv4,
         ipv6: ipv6
       }}
    end
  end

  @doc "Serializes a Profile to a TOML-compatible map."
  @spec to_toml(t()) :: map()
  def to_toml(%__MODULE__{} = profile) do
    base = %{
      "connection" => %{
        "id" => profile.id,
        "type" => to_string(profile.type),
        "autoconnect" => profile.autoconnect,
        "autoconnect_priority" => profile.autoconnect_priority,
        "zone" => profile.zone
      }
    }

    base =
      if profile.interface do
        put_in(base, ["connection", "interface"], profile.interface)
      else
        base
      end

    base
    |> put_ethernet(profile.ethernet)
    |> put_ipv4(profile.ipv4)
    |> put_ipv6(profile.ipv6)
  end

  # Connection section

  defp parse_connection(toml) do
    conn = Map.get(toml, "connection", %{})

    with {:ok, id} <- require_string(conn, "id"),
         :ok <- validate_id(id),
         {:ok, type} <- parse_type(conn),
         {:ok, interface} <- validate_interface(Map.get(conn, "interface")),
         {:ok, priority} <- validate_priority(Map.get(conn, "autoconnect_priority", 0)),
         {:ok, zone} <- validate_zone(Map.get(conn, "zone", "default")) do
      {:ok,
       %{
         id: id,
         type: type,
         interface: interface,
         autoconnect: Map.get(conn, "autoconnect", true),
         autoconnect_priority: priority,
         zone: zone
       }}
    end
  end

  defp parse_type(conn) do
    case Map.get(conn, "type") do
      nil -> {:error, "connection.type is required"}
      type when type in @valid_types -> {:ok, String.to_existing_atom(type)}
      other -> {:error, "invalid connection.type: #{inspect(other)}"}
    end
  end

  # Ethernet section

  defp parse_ethernet(toml) do
    eth = Map.get(toml, "ethernet", %{})
    mtu = Map.get(eth, "mtu")

    cond do
      mtu != nil and (not is_integer(mtu) or mtu < 68 or mtu > 65535) ->
        {:error, "ethernet.mtu must be an integer between 68 and 65535"}

      true ->
        {:ok, %{mtu: mtu}}
    end
  end

  # IPv4 section

  defp parse_ipv4(toml) do
    ipv4 = Map.get(toml, "ipv4", %{})
    method_str = Map.get(ipv4, "method", "auto")

    if method_str in @valid_ipv4_methods do
      method = parse_ip_method(method_str)
      address = Map.get(ipv4, "address")

      cond do
        method == :manual and (address == nil or address == "") ->
          {:error, "ipv4.address is required when method is manual"}

        method == :manual and not valid_cidr?(address) ->
          {:error, "ipv4.address must be valid CIDR (e.g. 192.168.1.1/24)"}

        true ->
          gateway = Map.get(ipv4, "gateway")
          dns = Map.get(ipv4, "dns", [])
          dns_search = Map.get(ipv4, "dns_search", [])

          with :ok <- validate_gateway(gateway, "ipv4"),
               :ok <- validate_dns_list(dns, "ipv4"),
               :ok <- validate_dns_search(dns_search, "ipv4") do
            {:ok,
             %{method: method, address: address, gateway: gateway, dns: dns, dns_search: dns_search}}
          end
      end
    else
      {:error, "invalid ipv4.method: #{inspect(method_str)}"}
    end
  end

  # IPv6 section

  defp parse_ipv6(toml) do
    ipv6 = Map.get(toml, "ipv6", %{})
    method_str = Map.get(ipv6, "method", "auto")

    if method_str in @valid_ipv6_methods do
      method = parse_ip_method(method_str)
      address = Map.get(ipv6, "address")

      cond do
        method == :manual and (address == nil or address == "") ->
          {:error, "ipv6.address is required when method is manual"}

        method == :manual and not valid_cidr?(address) ->
          {:error, "ipv6.address must be valid CIDR (e.g. fd00::1/64)"}

        true ->
          gateway = Map.get(ipv6, "gateway")
          dns = Map.get(ipv6, "dns", [])
          dns_search = Map.get(ipv6, "dns_search", [])

          with :ok <- validate_gateway(gateway, "ipv6"),
               :ok <- validate_dns_list(dns, "ipv6"),
               :ok <- validate_dns_search(dns_search, "ipv6") do
            {:ok,
             %{
               method: method,
               address: address,
               gateway: gateway,
               dns: dns,
               dns_search: dns_search
             }}
          end
      end
    else
      {:error, "invalid ipv6.method: #{inspect(method_str)}"}
    end
  end

  defp parse_ip_method("auto"), do: :auto
  defp parse_ip_method("manual"), do: :manual
  defp parse_ip_method("disabled"), do: :disabled
  defp parse_ip_method("link-local"), do: :link_local

  # Linux IFNAMSIZ is 16 (including null terminator), so max name length is 15.
  # Names must not contain spaces, slashes, or colons (reserved for VLAN syntax).
  @max_ifname_len 15

  defp validate_interface(nil), do: {:ok, nil}

  defp validate_interface(name) when is_binary(name) do
    cond do
      byte_size(name) == 0 ->
        {:error, "connection.interface must not be empty"}

      byte_size(name) > @max_ifname_len ->
        {:error, "connection.interface must be at most #{@max_ifname_len} characters"}

      String.contains?(name, [" ", "/", ":", "\t", "\n"]) ->
        {:error, "connection.interface contains invalid characters"}

      true ->
        {:ok, name}
    end
  end

  defp validate_interface(other) do
    {:error, "connection.interface must be a string, got: #{inspect(other)}"}
  end

  defp validate_gateway(nil, _section), do: :ok

  defp validate_gateway(gw, section) when is_binary(gw) do
    case :inet.parse_address(String.to_charlist(gw)) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "#{section}.gateway is not a valid IP address: #{gw}"}
    end
  end

  defp validate_gateway(other, section) do
    {:error, "#{section}.gateway must be a string, got: #{inspect(other)}"}
  end

  defp validate_dns_list(list, section) when is_list(list) do
    invalid =
      Enum.reject(list, fn
        s when is_binary(s) ->
          match?({:ok, _}, :inet.parse_address(String.to_charlist(s)))

        _ ->
          false
      end)

    if invalid == [] do
      :ok
    else
      {:error, "#{section}.dns contains invalid addresses: #{inspect(invalid)}"}
    end
  end

  defp validate_dns_list(other, section) do
    {:error, "#{section}.dns must be a list, got: #{inspect(other)}"}
  end

  @domain_pattern ~r/^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*\.?$/

  defp validate_dns_search(list, section) when is_list(list) do
    invalid =
      Enum.reject(list, fn
        s when is_binary(s) and byte_size(s) > 0 and byte_size(s) <= 253 ->
          Regex.match?(@domain_pattern, s)

        _ ->
          false
      end)

    if invalid == [] do
      :ok
    else
      {:error, "#{section}.dns_search contains invalid domain names: #{inspect(invalid)}"}
    end
  end

  defp validate_dns_search(other, section) do
    {:error, "#{section}.dns_search must be a list, got: #{inspect(other)}"}
  end

  defp valid_cidr?(cidr) when is_binary(cidr) do
    case String.split(cidr, "/") do
      [addr, prefix] ->
        case {Integer.parse(prefix), :inet.parse_address(String.to_charlist(addr))} do
          {{n, ""}, {:ok, {_, _, _, _}}} when n >= 0 and n <= 32 -> true
          {{n, ""}, {:ok, {_, _, _, _, _, _, _, _}}} when n >= 0 and n <= 128 -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_cidr?(_), do: false

  @max_id_length 128
  @id_pattern ~r/^[a-zA-Z0-9_\-\.]+$/

  defp validate_id(id) do
    cond do
      byte_size(id) > @max_id_length ->
        {:error, "connection.id is too long (max #{@max_id_length} characters)"}

      not Regex.match?(@id_pattern, id) ->
        {:error, "connection.id contains invalid characters (only alphanumeric, _, -, . allowed)"}

      true ->
        :ok
    end
  end

  defp validate_priority(priority)
       when is_integer(priority) and priority >= -1000 and priority <= 10_000 do
    {:ok, priority}
  end

  defp validate_priority(priority) when is_integer(priority) do
    {:error, "autoconnect_priority must be between -1000 and 10000"}
  end

  defp validate_priority(_), do: {:ok, 0}

  @max_zone_length 64
  @zone_pattern ~r/^[a-zA-Z0-9_\-\.]+$/

  defp validate_zone(zone) when is_binary(zone) do
    cond do
      byte_size(zone) > @max_zone_length ->
        {:error, "zone is too long (max #{@max_zone_length} characters)"}

      not Regex.match?(@zone_pattern, zone) ->
        {:error, "zone contains invalid characters"}

      true ->
        {:ok, zone}
    end
  end

  defp validate_zone(_), do: {:ok, "default"}

  defp require_string(map, key) do
    case Map.get(map, key) do
      nil -> {:error, "#{key} is required"}
      "" -> {:error, "#{key} must not be empty"}
      val when is_binary(val) -> {:ok, val}
      other -> {:error, "#{key} must be a string, got: #{inspect(other)}"}
    end
  end

  defp put_ethernet(map, %{mtu: nil}), do: map
  defp put_ethernet(map, %{mtu: mtu}), do: Map.put(map, "ethernet", %{"mtu" => mtu})

  defp put_ipv4(map, ipv4) do
    if ipv4.method == :auto and ipv4.address == nil and ipv4.gateway == nil and
         ipv4.dns == [] and Map.get(ipv4, :dns_search, []) == [] do
      map
    else
      section =
        %{"method" => serialize_method(ipv4.method)}
        |> maybe_put("address", ipv4.address)
        |> maybe_put("gateway", ipv4.gateway)
        |> maybe_put_list("dns", ipv4.dns)
        |> maybe_put_list("dns_search", Map.get(ipv4, :dns_search, []))

      Map.put(map, "ipv4", section)
    end
  end

  defp put_ipv6(map, ipv6) do
    if ipv6.method == :auto and ipv6.address == nil and ipv6.gateway == nil and
         ipv6.dns == [] and Map.get(ipv6, :dns_search, []) == [] do
      map
    else
      section =
        %{"method" => serialize_method(ipv6.method)}
        |> maybe_put("address", ipv6.address)
        |> maybe_put("gateway", ipv6.gateway)
        |> maybe_put_list("dns", ipv6.dns)
        |> maybe_put_list("dns_search", Map.get(ipv6, :dns_search, []))

      Map.put(map, "ipv6", section)
    end
  end

  defp serialize_method(:link_local), do: "link-local"
  defp serialize_method(method), do: to_string(method)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_list(map, _key, []), do: map
  defp maybe_put_list(map, key, list), do: Map.put(map, key, list)
end
