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
          dns: [String.t()]
        }

  @type ipv6_config :: %{
          method: ipv6_method(),
          address: String.t() | nil,
          gateway: String.t() | nil,
          dns: [String.t()]
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
    ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
    ipv6: %{method: :auto, address: nil, gateway: nil, dns: []}
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
         {:ok, type} <- parse_type(conn) do
      {:ok,
       %{
         id: id,
         type: type,
         interface: Map.get(conn, "interface"),
         autoconnect: Map.get(conn, "autoconnect", true),
         autoconnect_priority: Map.get(conn, "autoconnect_priority", 0),
         zone: Map.get(conn, "zone", "default")
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

      {:ok,
       %{
         method: method,
         address: Map.get(ipv4, "address"),
         gateway: Map.get(ipv4, "gateway"),
         dns: Map.get(ipv4, "dns", [])
       }}
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

      {:ok,
       %{
         method: method,
         address: Map.get(ipv6, "address"),
         gateway: Map.get(ipv6, "gateway"),
         dns: Map.get(ipv6, "dns", [])
       }}
    else
      {:error, "invalid ipv6.method: #{inspect(method_str)}"}
    end
  end

  defp parse_ip_method("auto"), do: :auto
  defp parse_ip_method("manual"), do: :manual
  defp parse_ip_method("disabled"), do: :disabled
  defp parse_ip_method("link-local"), do: :link_local

  defp require_string(map, key) do
    case Map.get(map, key) do
      nil -> {:error, "#{key} is required"}
      val when is_binary(val) -> {:ok, val}
      other -> {:error, "#{key} must be a string, got: #{inspect(other)}"}
    end
  end

  defp put_ethernet(map, %{mtu: nil}), do: map
  defp put_ethernet(map, %{mtu: mtu}), do: Map.put(map, "ethernet", %{"mtu" => mtu})

  defp put_ipv4(map, %{method: :auto, address: nil, gateway: nil, dns: []}), do: map

  defp put_ipv4(map, ipv4) do
    section =
      %{"method" => serialize_method(ipv4.method)}
      |> maybe_put("address", ipv4.address)
      |> maybe_put("gateway", ipv4.gateway)
      |> maybe_put_list("dns", ipv4.dns)

    Map.put(map, "ipv4", section)
  end

  defp put_ipv6(map, %{method: :auto, address: nil, gateway: nil, dns: []}), do: map

  defp put_ipv6(map, ipv6) do
    section =
      %{"method" => serialize_method(ipv6.method)}
      |> maybe_put("address", ipv6.address)
      |> maybe_put("gateway", ipv6.gateway)
      |> maybe_put_list("dns", ipv6.dns)

    Map.put(map, "ipv6", section)
  end

  defp serialize_method(:link_local), do: "link-local"
  defp serialize_method(method), do: to_string(method)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_list(map, _key, []), do: map
  defp maybe_put_list(map, key, list), do: Map.put(map, key, list)
end
