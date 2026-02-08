defmodule YellowDog.Console.FormatHelper do
  @moduledoc """
  Shared formatting helpers for DHCP lease display.

  Extracted from DHCPv4/v6 LiveView modules to eliminate duplication.
  Import this module in LiveViews that display MAC addresses, DUIDs,
  IPv4/IPv6 addresses, or lease timestamps.
  """

  @seconds_per_minute 60
  @seconds_per_hour 3_600
  @seconds_per_day 86_400
  @seconds_per_two_hours 7_200

  @doc "Formats a 6-byte MAC address binary as colon-separated hex."
  @spec format_mac(binary()) :: String.t()
  def format_mac(<<mac::binary-size(6)>>) do
    mac
    |> :binary.bin_to_list()
    |> Enum.map_join(":", fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
    |> String.upcase()
  end

  def format_mac(_), do: "Unknown"

  @doc "Formats an IP address (IPv4 or IPv6 tuple, binary, or nil) as a string."
  @spec format_ip(tuple() | binary() | nil) :: String.t() | nil
  def format_ip(ip) when tuple_size(ip) == 4, do: ip |> :inet.ntoa() |> to_string()

  def format_ip({a, b, c, d, e, f, g, h}),
    do: Enum.map_join([a, b, c, d, e, f, g, h], ":", &Integer.to_string(&1, 16))

  def format_ip(ip) when is_binary(ip), do: ip
  def format_ip(nil), do: nil
  def format_ip(_), do: "Unknown"

  @doc "Formats a DHCPv6 DUID binary as colon-separated hex."
  @spec format_duid(binary()) :: String.t()
  def format_duid(duid) when is_binary(duid) do
    duid
    |> :binary.bin_to_list()
    |> Enum.map_join(":", fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
    |> String.upcase()
  end

  def format_duid(_), do: "Unknown"

  @doc "Formats an IPv6 8-tuple as colon-separated hex."
  @spec format_ipv6(tuple()) :: String.t()
  def format_ipv6({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map_join(":", fn b -> b |> Integer.to_string(16) |> String.downcase() end)
  end

  def format_ipv6(_), do: "Unknown"

  @doc "Formats a unix timestamp as a human-readable datetime string."
  @spec format_expiration(integer()) :: String.t()
  def format_expiration(timestamp) when is_integer(timestamp) do
    DateTime.from_unix!(timestamp)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  def format_expiration(_), do: "N/A"

  @doc "Formats remaining time until expiration as a human-readable string."
  @spec format_time_remaining(integer()) :: String.t()
  def format_time_remaining(expires_at) when is_integer(expires_at) do
    remaining = expires_at - System.system_time(:second)

    cond do
      remaining <= 0 -> "Expired"
      remaining < @seconds_per_hour -> "#{div(remaining, @seconds_per_minute)}m remaining"
      remaining < @seconds_per_day -> "#{div(remaining, @seconds_per_hour)}h remaining"
      true -> "#{div(remaining, @seconds_per_day)}d remaining"
    end
  end

  def format_time_remaining(_), do: "N/A"

  @doc "Returns a DaisyUI text color class based on expiration proximity."
  @spec expiration_color(integer()) :: String.t()
  def expiration_color(expires_at) when is_integer(expires_at) do
    remaining = expires_at - System.system_time(:second)

    cond do
      remaining <= 0 -> "text-error"
      remaining < @seconds_per_hour -> "text-error"
      remaining < @seconds_per_two_hours -> "text-warning"
      true -> "text-base-content/50"
    end
  end

  def expiration_color(_), do: "text-base-content/50"

  @doc "Formats an IPv6 prefix tuple as address/length."
  @spec format_prefix({tuple(), non_neg_integer()}) :: String.t()
  def format_prefix({{a, b, c, d, e, f, g, h}, len}) do
    "#{format_ipv6({a, b, c, d, e, f, g, h})}/#{len}"
  end

  def format_prefix(_), do: "Unknown"

  @doc "Formats a duration in seconds as a compact human-readable string."
  @spec format_duration(integer()) :: String.t()
  def format_duration(seconds) when is_integer(seconds) do
    cond do
      seconds < @seconds_per_minute -> "#{seconds}s"
      seconds < @seconds_per_hour -> "#{div(seconds, @seconds_per_minute)}m"
      seconds < @seconds_per_day -> "#{div(seconds, @seconds_per_hour)}h"
      true -> "#{div(seconds, @seconds_per_day)}d"
    end
  end

  def format_duration(_), do: "N/A"

  @doc "Formats remaining time until a unix timestamp as a compact string."
  @spec format_expires(integer()) :: String.t()
  def format_expires(expires_at) when is_integer(expires_at) do
    remaining = expires_at - System.system_time(:second)

    cond do
      remaining < 0 -> "Expired"
      remaining < @seconds_per_minute -> "#{remaining}s"
      remaining < @seconds_per_hour -> "#{div(remaining, @seconds_per_minute)}m"
      remaining < @seconds_per_day -> "#{div(remaining, @seconds_per_hour)}h"
      true -> "#{div(remaining, @seconds_per_day)}d"
    end
  end

  def format_expires(_), do: "N/A"

  @doc "Formats a DHCPv6 IA type atom as a short label."
  @spec format_ia_type(atom()) :: String.t()
  def format_ia_type(:ia_na), do: "IA_NA"
  def format_ia_type(:ia_ta), do: "IA_TA"
  def format_ia_type(:ia_pd), do: "IA_PD"
  def format_ia_type(type), do: to_string(type)

  @doc "Parses a colon-separated hex MAC string into a 6-byte binary."
  @spec parse_mac_string(String.t()) :: binary()
  def parse_mac_string(mac_string) do
    case mac_string |> String.replace(":", "") |> String.upcase() |> Base.decode16() do
      {:ok, binary} -> binary
      :error -> <<0, 0, 0, 0, 0, 0>>
    end
  end

  @doc "Filters a list of country maps by search query (case-insensitive code/name match)."
  @spec filtered_countries([map()], String.t()) :: [map()]
  def filtered_countries(countries, ""), do: countries

  def filtered_countries(countries, search) do
    search_lower = String.downcase(search)

    Enum.filter(countries, fn %{code: code, name: name} ->
      String.contains?(String.downcase(name), search_lower) or
        String.contains?(String.downcase(code), search_lower)
    end)
  end

  @doc "Filters pools by name, network, or range start IP address."
  @spec filtered_pools(list(), String.t()) :: list()
  def filtered_pools(pools, ""), do: pools

  def filtered_pools(pools, filter) do
    term = String.downcase(filter)

    Enum.filter(pools, fn pool ->
      String.contains?(String.downcase(pool.name), term) or
        String.contains?(String.downcase(pool[:network] || ""), term) or
        String.contains?(String.downcase(format_ip(pool.range_start) || ""), term)
    end)
  end

  @doc "Filters a list by state field (atom) against a string value."
  @spec filter_by_state(list(), String.t()) :: list()
  def filter_by_state(items, "all"), do: items

  def filter_by_state(items, state),
    do: Enum.filter(items, fn item -> to_string(item.state) == state end)

  @doc "Filters a list by pool_name field against a string value."
  @spec filter_by_pool(list(), String.t()) :: list()
  def filter_by_pool(items, "all"), do: items
  def filter_by_pool(items, pool), do: Enum.filter(items, fn item -> item.pool_name == pool end)

  @doc "Parses a colon-separated hex DUID string into a binary."
  @spec parse_duid_string(String.t()) :: binary()
  def parse_duid_string(duid_str) do
    duid_str
    |> String.split(":")
    |> Enum.map(fn hex ->
      case Integer.parse(hex, 16) do
        {n, ""} -> n
        _ -> 0
      end
    end)
    |> :binary.list_to_bin()
  end
end
