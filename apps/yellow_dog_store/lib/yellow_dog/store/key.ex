defmodule YellowDog.Store.Key do
  @moduledoc """
  Structured key encoding for the Store facade.

  All Concord keys are UTF-8 strings with `:` separator.
  This module handles encoding/decoding between typed Elixir
  arguments and canonical string keys.
  """

  @view_pattern ~r/\A[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?\z/
  @dns_label_pattern ~r/\A[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?\z/
  @control_character_pattern ~r/[\x00-\x1F\x7F]/
  @max_rr_type_bytes 64

  @doc "Validate a view and DNS zone, returning both key segments verbatim."
  @spec canonical_zone_scope(term(), term()) ::
          {:ok, {String.t(), String.t()}} | {:error, :invalid_scope}
  def canonical_zone_scope(view_name, zone_name) do
    with {:ok, view_name} <- canonical_view(view_name),
         {:ok, zone_name} <- canonical_dns_name(zone_name, false) do
      {:ok, {view_name, zone_name}}
    else
      _error -> {:error, :invalid_scope}
    end
  end

  @doc "Validate a DNS owner name, returning the key segment verbatim."
  @spec canonical_owner(term()) :: {:ok, String.t()} | {:error, :invalid_owner}
  def canonical_owner("@"), do: {:ok, "@"}

  def canonical_owner(owner) do
    case canonical_dns_name(owner, true) do
      {:ok, owner} -> {:ok, owner}
      :error -> {:error, :invalid_owner}
    end
  end

  @doc "Return whether an existing atom can be encoded safely in an RR key."
  @spec valid_rr_type?(term()) :: boolean()
  def valid_rr_type?(type) when is_atom(type) and not is_nil(type) do
    encoded = Atom.to_string(type)

    String.valid?(encoded) and byte_size(encoded) in 1..@max_rr_type_bytes and
      not String.contains?(encoded, ":") and
      not Regex.match?(@control_character_pattern, encoded)
  end

  def valid_rr_type?(_type), do: false

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

  @doc "Zone metadata key (view-scoped)."
  @spec zone(String.t(), String.t()) :: String.t()
  def zone(view_name, zone_name), do: "dns:view:#{view_name}:zone:#{zone_name}"

  @doc "DNS provider configuration key."
  @spec provider_config(String.t()) :: String.t()
  def provider_config(name), do: "dns:provider:#{name}:config"

  @doc "Zone metadata key (legacy, default view)."
  @deprecated "Use zone/2 with explicit view_name"
  @spec zone(String.t()) :: String.t()
  def zone(name), do: zone("default", name)

  @doc "Zone resource record key (view-scoped)."
  @spec zone_rr(String.t(), String.t(), String.t(), atom()) :: String.t()
  def zone_rr(view_name, zone_name, owner, type),
    do: "dns:view:#{view_name}:zone:#{zone_name}:rr:#{owner}:#{type}"

  @doc "Zone resource record key (legacy, default view)."
  @deprecated "Use zone_rr/4 with explicit view_name"
  @spec zone_rr(String.t(), String.t(), atom()) :: String.t()
  def zone_rr(zone_name, owner, type), do: zone_rr("default", zone_name, owner, type)

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

  @doc "Durable zone replacement header key, outside observable DNS namespaces."
  @spec zone_replacement_header(String.t(), String.t()) :: String.t()
  def zone_replacement_header(view_name, zone_name),
    do: "store:zone-replacement:header:#{view_name}:#{zone_name}"

  @doc "Immutable zone replacement plan chunk key."
  @spec zone_replacement_plan(String.t(), non_neg_integer()) :: String.t()
  def zone_replacement_plan(operation_id, chunk_index),
    do: "#{zone_replacement_plan_prefix(operation_id)}#{chunk_index}"

  @doc "Durable replacement event key, unique by operation and event cursor."
  @spec zone_replacement_event(String.t(), non_neg_integer()) :: String.t()
  def zone_replacement_event(operation_id, cursor),
    do: "#{zone_replacement_event_prefix(operation_id)}#{cursor}"

  @doc "Task job key."
  @spec task_job(atom() | String.t(), String.t()) :: String.t()
  def task_job(task_key, id), do: "#{task_job_prefix(task_key)}#{id}"

  @doc "Task scheduler reservation key."
  @spec task_schedule(atom() | String.t()) :: String.t()
  def task_schedule(task_key), do: "tasks:schedule:#{task_key}"

  @doc "Task scheduler configuration key."
  @spec task_config(atom() | String.t()) :: String.t()
  def task_config(task_key), do: "tasks:config:#{task_key}"

  # Key prefix constants for prefix scans

  def lease_v4_prefix, do: "dhcp:lease:v4:"
  def lease_v6_prefix, do: "dhcp:lease:v6:"
  def device_prefix, do: "device:"
  def dyn_dns_prefix, do: "dns:dyn:"
  def provider_config_prefix, do: "dns:provider:"
  def task_job_prefix, do: "tasks:job:"
  def task_job_prefix(task_key), do: "tasks:job:#{task_key}:"
  def task_schedule_prefix, do: "tasks:schedule:"
  def task_config_prefix, do: "tasks:config:"

  @doc "Prefix for all zones across all views."
  def all_views_prefix, do: "dns:view:"

  @doc "Prefix for a specific view."
  def view_prefix(view_name), do: "dns:view:#{view_name}:"

  @doc "Prefix for all zones in a view."
  def zone_prefix(view_name), do: "dns:view:#{view_name}:zone:"

  @doc "Prefix for all RRsets in a zone (view-scoped)."
  def zone_rr_prefix(view_name, zone_name),
    do: "dns:view:#{view_name}:zone:#{zone_name}:rr:"

  @deprecated "Use zone_prefix/1 with view_name or all_views_prefix/0"
  def zone_prefix, do: zone_prefix("default")

  @doc "Prefix for all RRsets of a specific owner in a zone (view-scoped)."
  def zone_rr_owner_prefix(view_name, zone_name, owner),
    do: "dns:view:#{view_name}:zone:#{zone_name}:rr:#{owner}:"

  @deprecated "Use zone_rr_prefix/2 with view_name"
  def zone_rr_prefix(zone_name), do: zone_rr_prefix("default", zone_name)

  def cache_prefix, do: "dns:cache:"
  def rpz_prefix(zone_name), do: "rpz:#{zone_name}:"
  def rpz_all_prefix, do: "rpz:"
  def config_prefix(service), do: "config:#{service}:"
  def event_log_prefix, do: "event_log:"
  def zone_replacement_header_prefix, do: "store:zone-replacement:header:"

  def zone_replacement_event_prefix,
    do: "event_log:zone-replacement:"

  def zone_replacement_event_prefix(operation_id),
    do: "#{zone_replacement_event_prefix()}#{operation_id}:"

  def zone_replacement_plan_prefix(operation_id),
    do: "store:zone-replacement:plan:#{operation_id}:"

  @doc "DNS provider status key."
  @spec provider_status(String.t()) :: String.t()
  def provider_status(name), do: "dns:provider:#{name}:status"

  @doc "DNS provider conflict key."
  @spec provider_conflict(String.t(), String.t()) :: String.t()
  def provider_conflict(name, conflict_id), do: "dns:provider:#{name}:conflict:#{conflict_id}"

  @doc "Prefix for all provider keys."
  def provider_prefix, do: "dns:provider:"

  @doc "Prefix for a specific provider's keys."
  def provider_prefix(name), do: "dns:provider:#{name}:"

  @doc "Prefix for a specific provider's conflicts."
  def provider_conflict_prefix(name), do: "dns:provider:#{name}:conflict:"

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

  defp canonical_view(view_name) when is_binary(view_name) do
    if String.valid?(view_name) and String.trim(view_name) == view_name and
         byte_size(view_name) in 1..253 and Regex.match?(@view_pattern, view_name) do
      {:ok, view_name}
    else
      :error
    end
  end

  defp canonical_view(_view_name), do: :error

  defp canonical_dns_name(name, allow_wildcard?) when is_binary(name) do
    if String.valid?(name) and String.trim(name) == name and
         valid_dns_name?(name, allow_wildcard?) do
      {:ok, name}
    else
      :error
    end
  end

  defp canonical_dns_name(_name, _allow_wildcard?), do: :error

  defp valid_dns_name?(".", _allow_wildcard?), do: true

  defp valid_dns_name?(name, allow_wildcard?) do
    validation_name = remove_optional_root_dot(name)
    max_size = if String.ends_with?(name, "."), do: 254, else: 253

    byte_size(name) in 1..max_size and
      validation_name
      |> String.split(".")
      |> Enum.with_index()
      |> Enum.all?(fn
        {"*", 0} when allow_wildcard? ->
          true

        {label, _index} ->
          byte_size(label) in 1..63 and Regex.match?(@dns_label_pattern, label)
      end)
  end

  defp remove_optional_root_dot(name) do
    if String.ends_with?(name, ".") do
      binary_part(name, 0, byte_size(name) - 1)
    else
      name
    end
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
