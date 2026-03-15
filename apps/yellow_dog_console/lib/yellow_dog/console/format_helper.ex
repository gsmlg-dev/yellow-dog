defmodule YellowDog.Console.FormatHelper do
  @moduledoc """
  Shared formatting helpers for DHCP lease display.

  Extracted from DHCPv4/v6 LiveView modules to eliminate duplication.
  Import this module in LiveViews that display MAC addresses, DUIDs,
  IPv4/IPv6 addresses, or lease timestamps.
  """

  import YellowDog.Console.StringHelper, only: [downcase_contains?: 2]

  @seconds_per_minute 60
  @seconds_per_hour 3_600
  @seconds_per_day 86_400
  @seconds_per_two_hours 7_200

  @doc "Formats a 6-byte MAC address binary as colon-separated hex."
  @spec format_mac(term()) :: String.t()
  def format_mac(mac), do: YellowDog.Dhcpv4.MacFormat.format!(mac, default: "Unknown")

  @doc "Formats an IP address (IPv4 or IPv6 tuple, binary, or nil) as a string."
  @spec format_ip(tuple() | binary() | nil) :: String.t() | nil
  def format_ip(ip) when tuple_size(ip) == 4, do: ip |> :inet.ntoa() |> to_string()

  def format_ip({a, b, c, d, e, f, g, h}),
    do: Enum.map_join([a, b, c, d, e, f, g, h], ":", &Integer.to_string(&1, 16))

  def format_ip(ip) when is_binary(ip), do: ip
  def format_ip(nil), do: nil
  def format_ip(_), do: "Unknown"

  @doc "Formats a DHCPv6 DUID binary as colon-separated hex."
  @spec format_duid(term()) :: String.t()
  def format_duid(duid), do: YellowDog.Dhcpv6.DuidFormat.format!(duid, default: "Unknown")

  @doc "Formats an IPv6 8-tuple as colon-separated hex."
  @spec format_ipv6(term()) :: String.t()
  def format_ipv6(addr) when is_tuple(addr) and tuple_size(addr) == 8,
    do: YellowDog.Dhcpv6.Ipv6Util.format(addr)

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
      remaining < @seconds_per_hour -> "text-error"
      remaining < @seconds_per_two_hours -> "text-warning"
      true -> "text-on-surface-variant"
    end
  end

  def expiration_color(_), do: "text-on-surface-variant"

  @doc "Formats an IPv6 prefix tuple as address/length."
  @spec format_prefix({tuple(), non_neg_integer()}) :: String.t()
  def format_prefix({{a, b, c, d, e, f, g, h}, len}) do
    "#{format_ipv6({a, b, c, d, e, f, g, h})}/#{len}"
  end

  def format_prefix(_), do: "Unknown"

  @doc "Formats a DateTime or unix timestamp as HH:MM:SS."
  @spec format_time(DateTime.t() | integer() | nil) :: String.t()
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  def format_time(ts) when is_integer(ts), do: ts |> DateTime.from_unix!() |> format_time()
  def format_time(_), do: ""

  @doc "Formats a DateTime or unix nanosecond timestamp as HH:MM:SS.mmm (with milliseconds)."
  @spec format_time_ms(DateTime.t() | integer() | nil) :: String.t()
  def format_time_ms(ts) when is_integer(ts),
    do: ts |> DateTime.from_unix!(:nanosecond) |> format_time_ms()

  def format_time_ms(%DateTime{microsecond: {us, _}} = dt) do
    ms = div(us, 1000)
    Calendar.strftime(dt, "%H:%M:%S") <> "." <> String.pad_leading(Integer.to_string(ms), 3, "0")
  end

  def format_time_ms(_), do: "--:--:--.---"

  @doc "Formats a duration in seconds as compound human-readable (e.g. '1h 5m')."
  @spec format_uptime(number()) :: String.t()
  def format_uptime(seconds) when is_number(seconds) do
    s = trunc(seconds)
    hours = div(s, @seconds_per_hour)
    mins = div(rem(s, @seconds_per_hour), @seconds_per_minute)

    cond do
      hours > 0 -> "#{hours}h #{mins}m"
      mins > 0 -> "#{mins}m #{rem(s, @seconds_per_minute)}s"
      true -> "#{s}s"
    end
  end

  def format_uptime(_), do: "0s"

  @kb 1024
  @mb 1024 * 1024
  @gb 1024 * 1024 * 1024

  @doc "Formats a byte count as a human-readable string (B/KB/MB/GB)."
  @spec format_bytes(integer() | nil) :: String.t()
  def format_bytes(nil), do: "N/A"
  def format_bytes(bytes) when is_integer(bytes) and bytes < @kb, do: "#{bytes}B"

  def format_bytes(bytes) when is_integer(bytes) and bytes < @mb,
    do: "#{Float.round(bytes / @kb, 2)}KB"

  def format_bytes(bytes) when is_integer(bytes) and bytes < @gb,
    do: "#{Float.round(bytes / @mb, 2)}MB"

  def format_bytes(bytes) when is_integer(bytes), do: "#{Float.round(bytes / @gb, 2)}GB"
  def format_bytes(_), do: "N/A"

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

  @doc "Formats a unix timestamp as 'Xs ago', 'Xm ago', 'Xh ago', or 'Xd ago'."
  @spec format_time_ago(integer() | nil) :: String.t()
  def format_time_ago(timestamp) when is_integer(timestamp) do
    diff = System.system_time(:second) - timestamp

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  def format_time_ago(_), do: "Unknown"

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
      downcase_contains?(name, search_lower) or downcase_contains?(code, search_lower)
    end)
  end

  @doc "Filters pools by name, network, or range start IP address."
  @spec filtered_pools(list(), String.t()) :: list()
  def filtered_pools(pools, ""), do: pools

  def filtered_pools(pools, filter) do
    term = String.downcase(filter)

    Enum.filter(pools, fn pool ->
      downcase_contains?(pool.name, term) or
        downcase_contains?(pool[:network], term) or
        downcase_contains?(format_ip(pool.range_start), term)
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

  @doc "Formats a list of IP addresses as display strings (for DNS server lists)."
  @spec format_dns_servers(list() | nil) :: [String.t()]
  def format_dns_servers(nil), do: []
  def format_dns_servers(servers) when is_list(servers), do: Enum.map(servers, &format_ip/1)

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
