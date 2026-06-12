defmodule YellowDog.Console.LogBroadcaster do
  @moduledoc """
  Broadcasts telemetry events to connected LiveView processes via PubSub.

  Attaches to ALL protocol-level telemetry events (DNS, DHCPv4, DHCPv6, mDNS,
  service lifecycle, config, etc.) and also to the explicit `[:yellow_dog, :log, *]`
  events emitted by `YellowDog.Telemetry.log/3`.

  Each event is formatted into a human-readable message and broadcast on the
  `"logs:stream"` PubSub topic as `{:log_event, level, measurements, metadata}`.
  """

  use GenServer

  alias YellowDog.Telemetry.LoggerHandlers

  @pubsub YellowDog.Console.PubSub
  @topic "logs:stream"

  # All protocol events that should appear in the realtime log.
  # This is the union of every event listed in LoggerHandlers' @handler_specs
  # plus the explicit log events emitted by YellowDog.Telemetry.log/3.
  @protocol_events [
    # Explicit log events (from YellowDog.Telemetry.log/3)
    [:yellow_dog, :log, :debug],
    [:yellow_dog, :log, :info],
    [:yellow_dog, :log, :warning],
    [:yellow_dog, :log, :error],
    # DNS
    [:yellow_dog, :dns, :query, :received],
    [:yellow_dog, :dns, :query, :completed],
    [:yellow_dog, :dns, :query, :error],
    [:yellow_dog, :dns, :cache, :hit],
    [:yellow_dog, :dns, :cache, :miss],
    [:yellow_dog, :dns, :zone, :loaded],
    [:yellow_dog, :dns, :zone, :error],
    [:yellow_dog, :dns, :server, :started],
    [:yellow_dog, :dns, :server, :stopped],
    # DNS query details
    [:yellow_dog, :dns, :query, :start],
    [:yellow_dog, :dns, :query, :complete],
    [:yellow_dog, :dns, :query, :forward],
    [:yellow_dog, :dns, :query, :forward_error],
    [:yellow_dog, :dns, :query, :recursive],
    [:yellow_dog, :dns, :query, :recursive_error],
    [:yellow_dog, :dns, :query, :iterate],
    [:yellow_dog, :dns, :query, :referral],
    [:yellow_dog, :dns, :cache, :store],
    [:yellow_dog, :dns, :cache, :cleanup],
    [:yellow_dog, :dns, :cache, :expired],
    # DNS root zone
    [:yellow_dog, :dns, :root_zone, :fetch],
    [:yellow_dog, :dns, :root_zone, :fetch_error],
    [:yellow_dog, :dns, :root_zone, :update],
    [:yellow_dog, :dns, :root_zone, :loaded],
    # DHCPv4
    [:yellow_dog, :dhcpv4, :lease, :requested],
    [:yellow_dog, :dhcpv4, :lease, :granted],
    [:yellow_dog, :dhcpv4, :lease, :released],
    [:yellow_dog, :dhcpv4, :lease, :expired],
    [:yellow_dog, :dhcpv4, :lease, :declined],
    [:yellow_dog, :dhcpv4, :server, :started],
    [:yellow_dog, :dhcpv4, :server, :stopped],
    # DHCPv6
    [:yellow_dog, :dhcpv6, :lease, :requested],
    [:yellow_dog, :dhcpv6, :lease, :granted],
    [:yellow_dog, :dhcpv6, :lease, :released],
    [:yellow_dog, :dhcpv6, :lease, :expired],
    [:yellow_dog, :dhcpv6, :lease, :declined],
    [:yellow_dog, :dhcpv6, :server, :started],
    [:yellow_dog, :dhcpv6, :server, :stopped],
    # mDNS
    [:yellow_dog, :mdns, :service, :registered],
    [:yellow_dog, :mdns, :service, :unregistered],
    [:yellow_dog, :mdns, :service, :announced],
    [:yellow_dog, :mdns, :query, :received],
    [:yellow_dog, :mdns, :response, :sent],
    [:yellow_dog, :mdns, :server, :started],
    [:yellow_dog, :mdns, :server, :stopped],
    # Service lifecycle
    [:yellow_dog, :service, :started],
    [:yellow_dog, :service, :stopped],
    # Application lifecycle
    [:yellow_dog, :application, :start],
    [:yellow_dog, :application, :stop],
    [:yellow_dog, :application, :error],
    # Config
    [:yellow_dog, :config, :loaded],
    [:yellow_dog, :config, :error],
    [:yellow_dog, :config, :validated],
    # Console
    [:yellow_dog, :console, :dashboard, :load],
    [:yellow_dog, :console, :dashboard, :error],
    [:yellow_dog, :console, :dashboard, :status_error],
    [:yellow_dog, :console, :settings, :update],
    [:yellow_dog, :console, :settings, :error],
    [:yellow_dog, :console, :settings, :config_load_error],
    [:yellow_dog, :console, :service, :action]
  ]

  @doc """
  Starts the LogBroadcaster GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the PubSub topic for log streaming.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl true
  def init(_opts) do
    # Detach any stale handler from a previous run/reload
    :telemetry.detach("yellow-dog-log-broadcaster")

    result =
      :telemetry.attach_many(
        "yellow-dog-log-broadcaster",
        @protocol_events,
        &__MODULE__.handle_telemetry_event/4,
        %{}
      )

    IO.puts("[LogBroadcaster] attached #{length(@protocol_events)} events: #{inspect(result)}")

    {:ok, %{}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach("yellow-dog-log-broadcaster")
    :ok
  end

  @doc false
  def handle_telemetry_event(event, measurements, metadata, _config) do
    case format_event(event, measurements, metadata) do
      nil ->
        :ok

      {level, app, message} ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          @topic,
          {:log_event, level, Map.put(measurements, :system_time, System.system_time()),
           Map.merge(metadata, %{app: app, message: message})}
        )
    end
  rescue
    e ->
      IO.puts("[LogBroadcaster] ERROR in handler: #{inspect(e)} for event #{inspect(event)}")
      :ok
  end

  # ── Explicit log events from YellowDog.Telemetry.log/3 ────────────────────
  defp format_event([:yellow_dog, :log, level], _m, metadata) do
    {level, Map.get(metadata, :app, :yellow_dog), Map.get(metadata, :message, "")}
  end

  # ── DNS events ─────────────────────────────────────────────────────────────
  defp format_event([:yellow_dog, :dns, :query, :received], _m, md) do
    {:info, :yellow_dog_dns,
     "DNS query: #{md[:query_name]} (#{md[:query_type]}) from #{LoggerHandlers.format_ip(md[:client_ip])}"}
  end

  defp format_event([:yellow_dog, :dns, :query, :completed], m, md) do
    {:info, :yellow_dog_dns,
     "DNS response: #{md[:query_name]} -> #{md[:response_code]} (#{LoggerHandlers.format_duration(m[:duration_us])}, #{m[:answer_count] || 0} answers)"}
  end

  defp format_event([:yellow_dog, :dns, :query, :error], _m, md) do
    {:error, :yellow_dog_dns, "DNS error: #{md[:query_name]} -> #{inspect(md[:error])}"}
  end

  defp format_event([:yellow_dog, :dns, :cache, action], _m, md)
       when action in [:hit, :miss, :store, :expired] do
    {:debug, :yellow_dog_dns, "DNS cache #{action}: #{md[:query_name]}"}
  end

  defp format_event([:yellow_dog, :dns, :cache, :cleanup], m, _md) do
    {:debug, :yellow_dog_dns,
     "DNS cache cleanup: #{m[:entries_removed] || 0} removed, #{m[:entries_remaining] || 0} remaining"}
  end

  defp format_event([:yellow_dog, :dns, :zone, :loaded], m, md) do
    {:info, :yellow_dog_dns,
     "DNS zone loaded: #{md[:zone_name]} (#{m[:record_count] || 0} records)"}
  end

  defp format_event([:yellow_dog, :dns, :zone, :error], _m, md) do
    {:error, :yellow_dog_dns, "DNS zone error: #{md[:zone_name]} -> #{inspect(md[:error])}"}
  end

  defp format_event([:yellow_dog, :dns, :server, :started], _m, md) do
    {:info, :yellow_dog_dns,
     "DNS server started on #{LoggerHandlers.format_ip(md[:listen_address])}:#{md[:port]}"}
  end

  defp format_event([:yellow_dog, :dns, :server, :stopped], _m, md) do
    {:info, :yellow_dog_dns, "DNS server stopped: #{md[:reason]}"}
  end

  defp format_event([:yellow_dog, :dns, :query, action], _m, md)
       when action in [:start, :complete] do
    {:debug, :yellow_dog_dns, "DNS query #{action}: #{md[:query_name]}"}
  end

  defp format_event([:yellow_dog, :dns, :query, :forward], _m, md) do
    {:debug, :yellow_dog_dns, "DNS forward: #{md[:query_name]} to #{md[:upstream]}"}
  end

  defp format_event([:yellow_dog, :dns, :query, :forward_error], _m, md) do
    {:warning, :yellow_dog_dns,
     "DNS forward error: #{md[:query_name]} -> #{inspect(md[:reason])}"}
  end

  defp format_event([:yellow_dog, :dns, :query, :recursive], _m, md) do
    {:debug, :yellow_dog_dns, "DNS recursive: #{md[:query_name]} -> #{md[:result]}"}
  end

  defp format_event([:yellow_dog, :dns, :query, :recursive_error], _m, md) do
    {:warning, :yellow_dog_dns,
     "DNS recursive error: #{md[:query_name]} -> #{inspect(md[:reason])}"}
  end

  defp format_event([:yellow_dog, :dns, :query, :iterate], _m, md) do
    {:debug, :yellow_dog_dns, "DNS iterate: #{md[:query_name]} -> #{md[:server]}"}
  end

  defp format_event([:yellow_dog, :dns, :query, :referral], _m, md) do
    {:debug, :yellow_dog_dns, "DNS referral: #{md[:query_name]} -> #{md[:zone]}"}
  end

  defp format_event([:yellow_dog, :dns, :root_zone, action], _m, md)
       when action in [:fetch, :update, :loaded] do
    {:info, :yellow_dog_dns, "Root zone #{action}: #{inspect(md[:source_url] || md[:source])}"}
  end

  defp format_event([:yellow_dog, :dns, :root_zone, :fetch_error], _m, md) do
    {:error, :yellow_dog_dns, "Root zone fetch error: #{inspect(md[:reason])}"}
  end

  # ── DHCPv4 events ──────────────────────────────────────────────────────────
  defp format_event([:yellow_dog, :dhcpv4, :lease, :requested], _m, md) do
    msg_type = md[:message_type] |> to_string() |> String.upcase()

    {:info, :yellow_dog_dhcpv4,
     "DHCPv4 #{msg_type}: #{LoggerHandlers.format_mac(md[:client_mac])}"}
  end

  defp format_event([:yellow_dog, :dhcpv4, :lease, :granted], m, md) do
    {:info, :yellow_dog_dhcpv4,
     "DHCPv4 lease granted: #{LoggerHandlers.format_ip(md[:ip_address])} to #{LoggerHandlers.format_mac(md[:client_mac])} (#{m[:lease_time] || 0}s)"}
  end

  defp format_event([:yellow_dog, :dhcpv4, :lease, :released], _m, md) do
    {:info, :yellow_dog_dhcpv4,
     "DHCPv4 lease released: #{LoggerHandlers.format_ip(md[:ip_address])} from #{LoggerHandlers.format_mac(md[:client_mac])}"}
  end

  defp format_event([:yellow_dog, :dhcpv4, :lease, :expired], m, md) do
    {:info, :yellow_dog_dhcpv4,
     "DHCPv4 leases expired: #{m[:count] || 1} in pool #{md[:pool_name]}"}
  end

  defp format_event([:yellow_dog, :dhcpv4, :lease, :declined], _m, md) do
    {:warning, :yellow_dog_dhcpv4,
     "DHCPv4 lease declined: #{LoggerHandlers.format_ip(md[:ip_address])} by #{LoggerHandlers.format_mac(md[:client_mac])}"}
  end

  defp format_event([:yellow_dog, :dhcpv4, :server, :started], _m, md) do
    {:info, :yellow_dog_dhcpv4,
     "DHCPv4 server started on #{LoggerHandlers.format_ip(md[:listen_address])}:#{md[:port]}"}
  end

  defp format_event([:yellow_dog, :dhcpv4, :server, :stopped], _m, md) do
    {:info, :yellow_dog_dhcpv4, "DHCPv4 server stopped: #{md[:reason]}"}
  end

  # ── DHCPv6 events ──────────────────────────────────────────────────────────
  defp format_event([:yellow_dog, :dhcpv6, :lease, :requested], _m, md) do
    msg_type = md[:message_type] |> to_string() |> String.upcase()

    {:info, :yellow_dog_dhcpv6,
     "DHCPv6 #{msg_type}: DUID #{LoggerHandlers.format_duid(md[:duid])}"}
  end

  defp format_event([:yellow_dog, :dhcpv6, :lease, :granted], m, md) do
    {:info, :yellow_dog_dhcpv6,
     "DHCPv6 lease granted: #{LoggerHandlers.format_ipv6(md[:ip_address])} to DUID #{LoggerHandlers.format_duid(md[:duid])} (#{m[:valid_lifetime] || 0}s)"}
  end

  defp format_event([:yellow_dog, :dhcpv6, :lease, :released], _m, md) do
    {:info, :yellow_dog_dhcpv6,
     "DHCPv6 lease released: #{LoggerHandlers.format_ipv6(md[:ip_address])} from DUID #{LoggerHandlers.format_duid(md[:duid])}"}
  end

  defp format_event([:yellow_dog, :dhcpv6, :lease, :expired], m, md) do
    {:info, :yellow_dog_dhcpv6,
     "DHCPv6 leases expired: #{m[:count] || 1} in pool #{md[:pool_name]}"}
  end

  defp format_event([:yellow_dog, :dhcpv6, :lease, :declined], _m, md) do
    {:warning, :yellow_dog_dhcpv6,
     "DHCPv6 lease declined: #{LoggerHandlers.format_ipv6(md[:ip_address])} by DUID #{LoggerHandlers.format_duid(md[:duid])}"}
  end

  defp format_event([:yellow_dog, :dhcpv6, :server, :started], _m, md) do
    {:info, :yellow_dog_dhcpv6,
     "DHCPv6 server started on [#{LoggerHandlers.format_ipv6(md[:listen_address])}]:#{md[:port]}"}
  end

  defp format_event([:yellow_dog, :dhcpv6, :server, :stopped], _m, md) do
    {:info, :yellow_dog_dhcpv6, "DHCPv6 server stopped: #{md[:reason]}"}
  end

  # ── mDNS events ────────────────────────────────────────────────────────────
  defp format_event([:yellow_dog, :mdns, :service, :registered], _m, md) do
    {:info, :yellow_dog_mdns,
     "mDNS service registered: #{md[:service_name]} (#{md[:service_type]}) on port #{md[:port]}"}
  end

  defp format_event([:yellow_dog, :mdns, :service, :unregistered], _m, md) do
    {:info, :yellow_dog_mdns, "mDNS service unregistered: #{md[:service_name]}"}
  end

  defp format_event([:yellow_dog, :mdns, :service, :announced], _m, md) do
    {:debug, :yellow_dog_mdns, "mDNS service announced: #{md[:service_name]}"}
  end

  defp format_event([:yellow_dog, :mdns, :query, :received], _m, md) do
    {:debug, :yellow_dog_mdns,
     "mDNS query: #{md[:query_name]} (#{md[:query_type]}) from #{LoggerHandlers.format_ip(md[:source_ip])}"}
  end

  defp format_event([:yellow_dog, :mdns, :response, :sent], m, md) do
    {:debug, :yellow_dog_mdns,
     "mDNS response sent: #{m[:record_count] || 0} records (#{md[:response_type] || :multicast})"}
  end

  defp format_event([:yellow_dog, :mdns, :server, :started], _m, md) do
    {:info, :yellow_dog_mdns,
     "mDNS server started on #{LoggerHandlers.format_ip(md[:multicast_address])}:#{md[:port]} (mode: #{md[:mode] || :responder})"}
  end

  defp format_event([:yellow_dog, :mdns, :server, :stopped], _m, md) do
    {:info, :yellow_dog_mdns, "mDNS server stopped: #{md[:reason]}"}
  end

  # ── Service lifecycle ──────────────────────────────────────────────────────
  defp format_event([:yellow_dog, :service, action], _m, md)
       when action in [:started, :stopped] do
    service = md[:service] |> to_string() |> String.upcase()
    {:info, :yellow_dog, "Service #{action}: #{service}"}
  end

  # ── Application lifecycle ──────────────────────────────────────────────────
  defp format_event([:yellow_dog, :application, :start], _m, md) do
    {:info, :yellow_dog, "Application start: #{md[:services]}"}
  end

  defp format_event([:yellow_dog, :application, :error], _m, md) do
    {:error, :yellow_dog, "Application error: #{md[:service]} - #{md[:reason]}"}
  end

  defp format_event([:yellow_dog, :application, :stop], _m, _md) do
    {:info, :yellow_dog, "Application stopping"}
  end

  # ── Config events ──────────────────────────────────────────────────────────
  defp format_event([:yellow_dog, :config, :loaded], _m, md) do
    {:info, :yellow_dog, "Config loaded: #{md[:config_file]}"}
  end

  defp format_event([:yellow_dog, :config, :validated], _m, md) do
    {:info, :yellow_dog,
     "Services: enabled=[#{md[:enabled_services]}] disabled=[#{md[:disabled_services]}]"}
  end

  defp format_event([:yellow_dog, :config, :error], _m, md) do
    {:warning, :yellow_dog, "Config error: #{md[:reason]}"}
  end

  # ── Console events ─────────────────────────────────────────────────────────
  defp format_event([:yellow_dog, :console | _rest], _m, md) do
    {:info, :yellow_dog_console, "Console: #{inspect(md)}"}
  end

  # ── Catch-all ──────────────────────────────────────────────────────────────
  defp format_event(_event, _m, _md), do: nil
end
