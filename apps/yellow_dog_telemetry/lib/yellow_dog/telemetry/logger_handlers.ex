defmodule YellowDog.Telemetry.LoggerHandlers do
  @moduledoc """
  Telemetry handler functions for logging protocol-specific events.

  This module provides handler functions that are attached to telemetry events
  and format them as Logger messages. Handlers are error-safe and will not
  crash the service if formatting fails.

  ## Usage

      # Attach all handlers at application startup
      YellowDog.Telemetry.LoggerHandlers.attach_all()

      # Detach all handlers (for testing or silent operation)
      YellowDog.Telemetry.LoggerHandlers.detach_all()

  ## Event Naming Convention

  All events follow the pattern: `[:yellow_dog, <service>, <resource>, <action>]`

  Examples:
  - `[:yellow_dog, :dns, :query, :received]`
  - `[:yellow_dog, :dhcpv4, :lease, :granted]`
  - `[:yellow_dog, :mdns, :service, :registered]`
  """

  require Logger

  # Handler IDs for tracking attached handlers
  @handler_ids [
    "yellow-dog-dns-logger",
    "yellow-dog-dhcpv4-logger",
    "yellow-dog-dhcpv6-logger",
    "yellow-dog-mdns-logger",
    "yellow-dog-service-logger"
  ]

  @doc """
  Returns the list of handler IDs used by this module.
  """
  @spec handler_ids() :: [String.t()]
  def handler_ids, do: @handler_ids

  @doc """
  Attaches all logger handlers to their respective telemetry events.

  Returns `:ok` on success. Handlers are idempotent - calling multiple times
  will not create duplicate handlers.
  """
  @spec attach_all() :: :ok
  def attach_all do
    # DNS events
    :telemetry.attach_many(
      "yellow-dog-dns-logger",
      [
        [:yellow_dog, :dns, :query, :received],
        [:yellow_dog, :dns, :query, :completed],
        [:yellow_dog, :dns, :query, :error],
        [:yellow_dog, :dns, :cache, :hit],
        [:yellow_dog, :dns, :cache, :miss],
        [:yellow_dog, :dns, :zone, :loaded],
        [:yellow_dog, :dns, :zone, :error],
        [:yellow_dog, :dns, :server, :started],
        [:yellow_dog, :dns, :server, :stopped]
      ],
      &handle_dns_event/4,
      %{level: :info}
    )

    # DHCPv4 events
    :telemetry.attach_many(
      "yellow-dog-dhcpv4-logger",
      [
        [:yellow_dog, :dhcpv4, :lease, :requested],
        [:yellow_dog, :dhcpv4, :lease, :granted],
        [:yellow_dog, :dhcpv4, :lease, :released],
        [:yellow_dog, :dhcpv4, :lease, :expired],
        [:yellow_dog, :dhcpv4, :lease, :declined],
        [:yellow_dog, :dhcpv4, :server, :started],
        [:yellow_dog, :dhcpv4, :server, :stopped]
      ],
      &handle_dhcpv4_event/4,
      %{level: :info}
    )

    # DHCPv6 events
    :telemetry.attach_many(
      "yellow-dog-dhcpv6-logger",
      [
        [:yellow_dog, :dhcpv6, :lease, :requested],
        [:yellow_dog, :dhcpv6, :lease, :granted],
        [:yellow_dog, :dhcpv6, :lease, :released],
        [:yellow_dog, :dhcpv6, :lease, :expired],
        [:yellow_dog, :dhcpv6, :lease, :declined],
        [:yellow_dog, :dhcpv6, :server, :started],
        [:yellow_dog, :dhcpv6, :server, :stopped]
      ],
      &handle_dhcpv6_event/4,
      %{level: :info}
    )

    # mDNS events
    :telemetry.attach_many(
      "yellow-dog-mdns-logger",
      [
        [:yellow_dog, :mdns, :service, :registered],
        [:yellow_dog, :mdns, :service, :unregistered],
        [:yellow_dog, :mdns, :service, :announced],
        [:yellow_dog, :mdns, :query, :received],
        [:yellow_dog, :mdns, :response, :sent],
        [:yellow_dog, :mdns, :server, :started],
        [:yellow_dog, :mdns, :server, :stopped]
      ],
      &handle_mdns_event/4,
      %{level: :info}
    )

    # Service lifecycle events
    :telemetry.attach_many(
      "yellow-dog-service-logger",
      [
        [:yellow_dog, :service, :started],
        [:yellow_dog, :service, :stopped]
      ],
      &handle_service_event/4,
      %{level: :info}
    )

    :ok
  end

  @doc """
  Detaches all logger handlers.

  Returns `:ok` on success. Safe to call even if handlers are not attached.
  """
  @spec detach_all() :: :ok
  def detach_all do
    Enum.each(@handler_ids, fn handler_id ->
      # Ignore errors from detaching non-existent handlers
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  # =============================================================================
  # DNS Event Handler
  # =============================================================================

  @doc false
  def handle_dns_event(event, measurements, metadata, config) do
    try do
      do_handle_dns_event(event, measurements, metadata, config)
    rescue
      error ->
        Logger.error(fn -> "Telemetry handler error: #{inspect(error)}" end)
    catch
      kind, value ->
        Logger.error(fn -> "Telemetry handler #{kind}: #{inspect(value)}" end)
    end
  end

  defp do_handle_dns_event([:yellow_dog, :dns, :query, :received], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "DNS query: #{metadata[:query_name]} (#{metadata[:query_type]}) from #{format_ip(metadata[:client_ip])}"
    end)
  end

  defp do_handle_dns_event([:yellow_dog, :dns, :query, :completed], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      duration = format_duration(measurements[:duration_us])
      answer_count = measurements[:answer_count] || 0
      "DNS response: #{metadata[:query_name]} -> #{metadata[:response_code]} (#{duration}, #{answer_count} answers)"
    end)
  end

  defp do_handle_dns_event([:yellow_dog, :dns, :query, :error], _measurements, metadata, _config) do
    Logger.log(:error, fn ->
      "DNS error: #{metadata[:query_name]} -> #{inspect(metadata[:error])}"
    end)
  end

  defp do_handle_dns_event([:yellow_dog, :dns, :cache, :hit], _measurements, metadata, _config) do
    Logger.log(:debug, fn ->
      "DNS cache hit: #{metadata[:query_name]} (TTL: #{metadata[:ttl]}s)"
    end)
  end

  defp do_handle_dns_event([:yellow_dog, :dns, :cache, :miss], _measurements, metadata, _config) do
    Logger.log(:debug, fn ->
      "DNS cache miss: #{metadata[:query_name]}"
    end)
  end

  defp do_handle_dns_event([:yellow_dog, :dns, :zone, :loaded], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      records = measurements[:record_count] || 0
      time_ms = measurements[:load_time_ms] || 0
      "DNS zone loaded: #{metadata[:zone_name]} (#{records} records, #{time_ms}ms)"
    end)
  end

  defp do_handle_dns_event([:yellow_dog, :dns, :zone, :error], _measurements, metadata, _config) do
    Logger.log(:error, fn ->
      "DNS zone error: #{metadata[:zone_name]} -> #{inspect(metadata[:error])}"
    end)
  end

  defp do_handle_dns_event([:yellow_dog, :dns, :server, :started], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "DNS server started on #{format_ip(metadata[:listen_address])}:#{metadata[:port]}"
    end)
  end

  defp do_handle_dns_event([:yellow_dog, :dns, :server, :stopped], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "DNS server stopped: #{metadata[:reason]}"
    end)
  end

  defp do_handle_dns_event(_event, _measurements, _metadata, _config), do: :ok

  # =============================================================================
  # DHCPv4 Event Handler
  # =============================================================================

  @doc false
  def handle_dhcpv4_event(event, measurements, metadata, config) do
    try do
      do_handle_dhcpv4_event(event, measurements, metadata, config)
    rescue
      error ->
        Logger.error(fn -> "Telemetry handler error: #{inspect(error)}" end)
    catch
      kind, value ->
        Logger.error(fn -> "Telemetry handler #{kind}: #{inspect(value)}" end)
    end
  end

  defp do_handle_dhcpv4_event([:yellow_dog, :dhcpv4, :lease, :requested], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      msg_type = metadata[:message_type] |> to_string() |> String.upcase()
      "DHCPv4 #{msg_type}: #{metadata[:client_mac]}"
    end)
  end

  defp do_handle_dhcpv4_event([:yellow_dog, :dhcpv4, :lease, :granted], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      lease_time = measurements[:lease_time] || 0
      "DHCPv4 lease granted: #{format_ip(metadata[:ip_address])} to #{metadata[:client_mac]} (#{lease_time}s)"
    end)
  end

  defp do_handle_dhcpv4_event([:yellow_dog, :dhcpv4, :lease, :released], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "DHCPv4 lease released: #{format_ip(metadata[:ip_address])} from #{metadata[:client_mac]}"
    end)
  end

  defp do_handle_dhcpv4_event([:yellow_dog, :dhcpv4, :lease, :expired], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      count = measurements[:count] || 1
      "DHCPv4 leases expired: #{count} leases in pool #{metadata[:pool_name]}"
    end)
  end

  defp do_handle_dhcpv4_event([:yellow_dog, :dhcpv4, :lease, :declined], _measurements, metadata, _config) do
    Logger.log(:warning, fn ->
      "DHCPv4 lease declined: #{format_ip(metadata[:ip_address])} by #{metadata[:client_mac]}"
    end)
  end

  defp do_handle_dhcpv4_event([:yellow_dog, :dhcpv4, :server, :started], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      pool_count = metadata[:pool_count] || 0
      "DHCPv4 server started on #{format_ip(metadata[:listen_address])}:#{metadata[:port]} (#{pool_count} pools)"
    end)
  end

  defp do_handle_dhcpv4_event([:yellow_dog, :dhcpv4, :server, :stopped], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "DHCPv4 server stopped: #{metadata[:reason]}"
    end)
  end

  defp do_handle_dhcpv4_event(_event, _measurements, _metadata, _config), do: :ok

  # =============================================================================
  # DHCPv6 Event Handler
  # =============================================================================

  @doc false
  def handle_dhcpv6_event(event, measurements, metadata, config) do
    try do
      do_handle_dhcpv6_event(event, measurements, metadata, config)
    rescue
      error ->
        Logger.error(fn -> "Telemetry handler error: #{inspect(error)}" end)
    catch
      kind, value ->
        Logger.error(fn -> "Telemetry handler #{kind}: #{inspect(value)}" end)
    end
  end

  defp do_handle_dhcpv6_event([:yellow_dog, :dhcpv6, :lease, :requested], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      msg_type = metadata[:message_type] |> to_string() |> String.upcase()
      duid_hex = format_duid(metadata[:duid])
      "DHCPv6 #{msg_type}: DUID #{duid_hex}"
    end)
  end

  defp do_handle_dhcpv6_event([:yellow_dog, :dhcpv6, :lease, :granted], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      valid_lifetime = measurements[:valid_lifetime] || 0
      duid_hex = format_duid(metadata[:duid])
      "DHCPv6 lease granted: #{format_ipv6(metadata[:ip_address])} to DUID #{duid_hex} (#{valid_lifetime}s)"
    end)
  end

  defp do_handle_dhcpv6_event([:yellow_dog, :dhcpv6, :lease, :released], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      duid_hex = format_duid(metadata[:duid])
      "DHCPv6 lease released: #{format_ipv6(metadata[:ip_address])} from DUID #{duid_hex}"
    end)
  end

  defp do_handle_dhcpv6_event([:yellow_dog, :dhcpv6, :lease, :expired], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      count = measurements[:count] || 1
      "DHCPv6 leases expired: #{count} leases in pool #{metadata[:pool_name]}"
    end)
  end

  defp do_handle_dhcpv6_event([:yellow_dog, :dhcpv6, :lease, :declined], _measurements, metadata, _config) do
    Logger.log(:warning, fn ->
      duid_hex = format_duid(metadata[:duid])
      "DHCPv6 lease declined: #{format_ipv6(metadata[:ip_address])} by DUID #{duid_hex}"
    end)
  end

  defp do_handle_dhcpv6_event([:yellow_dog, :dhcpv6, :server, :started], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      pool_count = metadata[:pool_count] || 0
      "DHCPv6 server started on [#{format_ipv6(metadata[:listen_address])}]:#{metadata[:port]} (#{pool_count} pools)"
    end)
  end

  defp do_handle_dhcpv6_event([:yellow_dog, :dhcpv6, :server, :stopped], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "DHCPv6 server stopped: #{metadata[:reason]}"
    end)
  end

  defp do_handle_dhcpv6_event(_event, _measurements, _metadata, _config), do: :ok

  # =============================================================================
  # mDNS Event Handler
  # =============================================================================

  @doc false
  def handle_mdns_event(event, measurements, metadata, config) do
    try do
      do_handle_mdns_event(event, measurements, metadata, config)
    rescue
      error ->
        Logger.error(fn -> "Telemetry handler error: #{inspect(error)}" end)
    catch
      kind, value ->
        Logger.error(fn -> "Telemetry handler #{kind}: #{inspect(value)}" end)
    end
  end

  defp do_handle_mdns_event([:yellow_dog, :mdns, :service, :registered], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "mDNS service registered: #{metadata[:service_name]} (#{metadata[:service_type]}) on port #{metadata[:port]}"
    end)
  end

  defp do_handle_mdns_event([:yellow_dog, :mdns, :service, :unregistered], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "mDNS service unregistered: #{metadata[:service_name]} (#{metadata[:service_type]})"
    end)
  end

  defp do_handle_mdns_event([:yellow_dog, :mdns, :service, :announced], _measurements, metadata, _config) do
    Logger.log(:debug, fn ->
      "mDNS service announced: #{metadata[:service_name]}"
    end)
  end

  defp do_handle_mdns_event([:yellow_dog, :mdns, :query, :received], _measurements, metadata, _config) do
    Logger.log(:debug, fn ->
      unicast = if metadata[:is_unicast], do: " (unicast)", else: ""
      "mDNS query: #{metadata[:query_name]} (#{metadata[:query_type]}) from #{format_ip(metadata[:source_ip])}#{unicast}"
    end)
  end

  defp do_handle_mdns_event([:yellow_dog, :mdns, :response, :sent], measurements, metadata, _config) do
    Logger.log(:debug, fn ->
      record_count = measurements[:record_count] || 0
      response_type = metadata[:response_type] || :multicast
      "mDNS response sent: #{record_count} records (#{response_type})"
    end)
  end

  defp do_handle_mdns_event([:yellow_dog, :mdns, :server, :started], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      mode = metadata[:mode] || :responder
      "mDNS server started on #{format_ip(metadata[:multicast_address])}:#{metadata[:port]} (mode: #{mode})"
    end)
  end

  defp do_handle_mdns_event([:yellow_dog, :mdns, :server, :stopped], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "mDNS server stopped: #{metadata[:reason]}"
    end)
  end

  defp do_handle_mdns_event(_event, _measurements, _metadata, _config), do: :ok

  # =============================================================================
  # Service Lifecycle Event Handler
  # =============================================================================

  @doc false
  def handle_service_event(event, _measurements, metadata, config) do
    try do
      do_handle_service_event(event, metadata, config)
    rescue
      error ->
        Logger.error(fn -> "Telemetry handler error: #{inspect(error)}" end)
    catch
      kind, value ->
        Logger.error(fn -> "Telemetry handler #{kind}: #{inspect(value)}" end)
    end
  end

  defp do_handle_service_event([:yellow_dog, :service, :started], metadata, config) do
    Logger.log(config.level, fn ->
      service = metadata[:service] |> to_string() |> String.upcase()
      "Service started: #{service}"
    end)
  end

  defp do_handle_service_event([:yellow_dog, :service, :stopped], metadata, config) do
    Logger.log(config.level, fn ->
      service = metadata[:service] |> to_string() |> String.upcase()
      "Service stopped: #{service}"
    end)
  end

  defp do_handle_service_event(_event, _metadata, _config), do: :ok

  # =============================================================================
  # Formatting Helpers
  # =============================================================================

  @doc """
  Formats an IPv4 address tuple as a dotted-decimal string.
  """
  @spec format_ip(tuple() | nil) :: String.t()
  def format_ip(nil), do: "unknown"
  def format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  def format_ip(ip) when is_tuple(ip) and tuple_size(ip) == 8, do: format_ipv6(ip)
  def format_ip(ip) when is_binary(ip), do: ip
  def format_ip(_), do: "unknown"

  @doc """
  Formats an IPv6 address tuple as a colon-separated hex string.
  """
  @spec format_ipv6(tuple() | nil) :: String.t()
  def format_ipv6(nil), do: "unknown"

  def format_ipv6({0, 0, 0, 0, 0, 0, 0, 0}), do: "::"

  def format_ipv6(ip) when is_tuple(ip) and tuple_size(ip) == 8 do
    ip
    |> Tuple.to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
    |> String.downcase()
  end

  def format_ipv6(ip) when is_binary(ip), do: ip
  def format_ipv6(_), do: "unknown"

  @doc """
  Formats a MAC address binary or string as XX:XX:XX:XX:XX:XX.
  """
  @spec format_mac(binary() | String.t() | nil) :: String.t()
  def format_mac(nil), do: "unknown"
  def format_mac(mac) when is_binary(mac) and byte_size(mac) == 6 do
    mac
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end
  def format_mac(mac) when is_binary(mac), do: mac
  def format_mac(_), do: "unknown"

  @doc """
  Formats a DUID binary as a hex string.
  """
  @spec format_duid(binary() | nil) :: String.t()
  def format_duid(nil), do: "unknown"
  def format_duid(duid) when is_binary(duid) do
    duid
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
    |> then(fn s -> if byte_size(duid) > 8, do: s <> "...", else: s end)
  end
  def format_duid(_), do: "unknown"

  @doc """
  Formats a duration in microseconds as a human-readable string.
  """
  @spec format_duration(integer() | nil) :: String.t()
  def format_duration(nil), do: "unknown"
  def format_duration(us) when is_integer(us) and us < 1000, do: "#{us}μs"
  def format_duration(us) when is_integer(us) and us < 1_000_000, do: "#{Float.round(us / 1000, 2)}ms"
  def format_duration(us) when is_integer(us), do: "#{Float.round(us / 1_000_000, 2)}s"
  def format_duration(_), do: "unknown"
end
