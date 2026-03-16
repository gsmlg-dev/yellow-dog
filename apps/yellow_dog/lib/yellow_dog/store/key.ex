defmodule YellowDog.Store.Key do
  @moduledoc """
  Structured key encoding for the Store facade.

  All Concord keys are UTF-8 strings with `:` separator.
  This module handles encoding/decoding between typed Elixir
  arguments and canonical string keys.
  """

  @doc "Build a DHCPv4 lease key from a MAC address."
  @spec lease_v4(String.t()) :: String.t()
  def lease_v4(mac), do: "dhcp:lease:v4:#{normalize_mac(mac)}"

  @doc "Build a DHCPv6 lease key from a DUID."
  @spec lease_v6(String.t()) :: String.t()
  def lease_v6(duid), do: "dhcp:lease:v6:#{normalize_duid(duid)}"

  @doc "Build a lease key for the given protocol and client ID."
  @spec lease(atom(), String.t()) :: String.t()
  def lease(:v4, mac), do: lease_v4(mac)
  def lease(:v6, duid), do: lease_v6(duid)

  @doc "DHCP pool key."
  @spec pool(String.t()) :: String.t()
  def pool(subnet), do: "dhcp:pool:#{subnet}"

  @doc "Device fingerprint key."
  @spec device(String.t()) :: String.t()
  def device(mac), do: "device:#{normalize_mac(mac)}"

  @doc "Dynamic DNS forward record key."
  @spec dyn_dns(String.t()) :: String.t()
  def dyn_dns(fqdn), do: "dns:dyn:#{fqdn}"

  @doc "Dynamic DNS reverse PTR key."
  @spec dyn_dns_ptr(String.t()) :: String.t()
  def dyn_dns_ptr(arpa), do: "dns:dyn:ptr:#{arpa}"

  @doc "Zone metadata key."
  @spec zone(String.t()) :: String.t()
  def zone(name), do: "dns:zone:#{name}"

  @doc "Zone resource record key."
  @spec zone_rr(String.t(), String.t(), atom()) :: String.t()
  def zone_rr(zone_name, owner, type), do: "dns:zone:#{zone_name}:rr:#{owner}:#{type}"

  @doc "DNS cache key."
  @spec cache(String.t(), atom()) :: String.t()
  def cache(qname, qtype), do: "dns:cache:#{qname}:#{qtype}"

  @doc "RPZ rule key."
  @spec rpz(String.t(), String.t()) :: String.t()
  def rpz(zone_name, trigger), do: "rpz:#{zone_name}:#{trigger}"

  @doc "Host identity key."
  @spec host(String.t()) :: String.t()
  def host(hostname), do: "host:#{hostname}"

  @doc "Runtime config key."
  @spec config(atom(), atom() | String.t()) :: String.t()
  def config(service, key), do: "config:#{service}:#{key}"

  @doc "Event log key."
  @spec event_log(integer(), String.t()) :: String.t()
  def event_log(timestamp, key), do: "event_log:#{timestamp}:#{key}"

  # Key prefix constants for prefix scans
  def lease_v4_prefix, do: "dhcp:lease:v4:"
  def lease_v6_prefix, do: "dhcp:lease:v6:"
  def device_prefix, do: "device:"
  def dyn_dns_prefix, do: "dns:dyn:"
  def zone_prefix, do: "dns:zone:"
  def zone_rr_prefix(zone_name), do: "dns:zone:#{zone_name}:rr:"
  def cache_prefix, do: "dns:cache:"
  def rpz_prefix(zone_name), do: "rpz:#{zone_name}:"
  def rpz_all_prefix, do: "rpz:"
  def config_prefix(service), do: "config:#{service}:"
  def event_log_prefix, do: "event_log:"

  @doc "Normalize MAC address to lowercase colon-separated format."
  @spec normalize_mac(String.t()) :: String.t()
  def normalize_mac(mac) do
    # Strip all separators, then re-chunk into colon-separated pairs
    mac
    |> String.downcase()
    |> String.replace(~r/[:\-.]/, "")
    |> normalize_mac_colons()
  end

  @doc "Normalize DUID to lowercase colon-separated hex."
  @spec normalize_duid(String.t()) :: String.t()
  def normalize_duid(duid) do
    duid
    |> String.downcase()
    |> String.replace(~r/[-.]/, ":")
  end

  # Re-chunk hex digits into colon-separated pairs: "aabbccddeeff" → "aa:bb:cc:dd:ee:ff"
  defp normalize_mac_colons(hex) do
    hex
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(":")
  end
end
