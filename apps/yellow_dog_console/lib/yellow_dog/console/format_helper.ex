defmodule YellowDog.Console.FormatHelper do
  @moduledoc """
  Shared formatting helpers for DHCP lease display.

  Extracted from DHCPv4/v6 LiveView modules to eliminate duplication.
  Import this module in LiveViews that display MAC addresses, DUIDs,
  IPv4/IPv6 addresses, or lease timestamps.
  """

  @doc "Formats a 6-byte MAC address binary as colon-separated hex."
  def format_mac(<<mac::binary-size(6)>>) do
    mac
    |> :binary.bin_to_list()
    |> Enum.map_join(":", fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
    |> String.upcase()
  end

  def format_mac(_), do: "Unknown"

  @doc "Formats an IPv4 tuple as dotted decimal."
  def format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  def format_ip(_), do: "Unknown"

  @doc "Formats a DHCPv6 DUID binary as colon-separated hex."
  def format_duid(duid) when is_binary(duid) do
    duid
    |> :binary.bin_to_list()
    |> Enum.map_join(":", fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
    |> String.upcase()
  end

  def format_duid(_), do: "Unknown"

  @doc "Formats an IPv6 8-tuple as colon-separated hex."
  def format_ipv6({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map_join(":", fn b -> b |> Integer.to_string(16) |> String.downcase() end)
  end

  def format_ipv6(_), do: "Unknown"

  @doc "Formats a unix timestamp as a human-readable datetime string."
  def format_expiration(timestamp) when is_integer(timestamp) do
    DateTime.from_unix!(timestamp)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  def format_expiration(_), do: "N/A"

  @doc "Formats remaining time until expiration as a human-readable string."
  def format_time_remaining(expires_at) when is_integer(expires_at) do
    remaining = expires_at - System.system_time(:second)

    cond do
      remaining <= 0 -> "Expired"
      remaining < 3600 -> "#{div(remaining, 60)}m remaining"
      remaining < 86400 -> "#{div(remaining, 3600)}h remaining"
      true -> "#{div(remaining, 86400)}d remaining"
    end
  end

  def format_time_remaining(_), do: "N/A"

  @doc "Returns a DaisyUI text color class based on expiration proximity."
  def expiration_color(expires_at) when is_integer(expires_at) do
    remaining = expires_at - System.system_time(:second)

    cond do
      remaining <= 0 -> "text-error"
      remaining < 3600 -> "text-error"
      remaining < 7200 -> "text-warning"
      true -> "text-base-content/50"
    end
  end

  def expiration_color(_), do: "text-base-content/50"

  @doc "Parses a colon-separated hex MAC string into a 6-byte binary."
  def parse_mac_string(mac_string) do
    mac_string
    |> String.replace(":", "")
    |> String.upcase()
    |> Base.decode16!()
  rescue
    _ -> <<0, 0, 0, 0, 0, 0>>
  end
end
