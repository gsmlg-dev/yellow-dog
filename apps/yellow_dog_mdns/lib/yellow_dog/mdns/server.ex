defmodule YellowDog.Mdns.Server do
  @moduledoc """
  mDNS server implementation using Abyss UDP server library.

  Provides multicast DNS functionality with proper socket configuration
  for mDNS multicast address (224.0.0.251:5353) and integration with
  the YellowDog configuration system.
  """

  require Logger
  alias YellowDog.Config

  @type options :: keyword()
  @type server_config :: map()

  # mDNS multicast address and port
  @mdns_multicast_address {224, 0, 0, 251}
  @mdns_port 5353

  @doc """
  Starts the mDNS server with the given options.

  ## Options
  - `:port` - UDP port to listen on (default: 5353)
  - `:listen_address` - IP address to listen on (default: from config)
  - `:multicast_address` - Multicast address to join (default: {224, 0, 0, 251})
  - `:handler_module` - Handler module for processing mDNS messages
  - `:broadcast` - Enable broadcast mode (default: true for mDNS)
  - `:transport_options` - Additional UDP transport options

  ## Examples
      iex> YellowDog.Mdns.Server.start_link([])
      {:ok, #PID<0.123.0>}
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if Config.service_enabled?(:mdns) do
      server_config = build_server_config(opts)
      port = Keyword.get(server_config, :port, 5353)
      Logger.info("Starting mDNS server on port #{port}")
      Abyss.start_link(server_config)
    else
      Logger.info("mDNS service is disabled in configuration")
      :ignore
    end
  end

  @doc """
  Stops the mDNS server.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Gets the current server configuration.
  """
  @spec get_config() :: server_config()
  def get_config do
    %{
      port: get_config_port(),
      listen_address: get_config_listen_address(),
      multicast_address: @mdns_multicast_address,
      service_enabled: Config.service_enabled?(:mdns)
    }
  end

  # Private functions

  defp build_server_config(opts) do
    port = Keyword.get(opts, :port, get_config_port())
    listen_address = Keyword.get(opts, :listen_address, get_config_listen_address())
    handler_module = Keyword.get(opts, :handler_module, YellowDog.Mdns.Handler)
    multicast_address = Keyword.get(opts, :multicast_address, @mdns_multicast_address)

    # Build transport options for multicast
    transport_options = build_transport_options(listen_address, multicast_address, opts)

    # Base abyss configuration
    [
      port: port,
      handler_module: handler_module,
      broadcast: Keyword.get(opts, :broadcast, true),
      transport_options: transport_options,
      # mDNS-specific configuration
      read_timeout: Keyword.get(opts, :read_timeout, 5000),
      num_listeners: Keyword.get(opts, :num_listeners, 1),  # Single listener for broadcast mode
      rate_limit_enabled: Keyword.get(opts, :rate_limit_enabled, false),  # Disabled for local mDNS
      max_packet_size: Keyword.get(opts, :max_packet_size, 1232)  # mDNS MTU limit
    ]
  end

  defp build_transport_options(listen_address, multicast_address, opts) do
    base_options = [
      {:ip, listen_address},
      {:multicast_if, listen_address},
      {:add_membership, {multicast_address, listen_address}},
      {:multicast_ttl, 255},  # mDNS uses TTL 255
      {:active, false}
    ]

    # Add any additional transport options from opts
    additional_opts = Keyword.get(opts, :transport_options, [])

    base_options ++ additional_opts
  end

  defp get_config_port do
    case Config.get(:mdns, :port) do
      nil -> @mdns_port
      port when is_integer(port) -> port
      port when is_binary(port) -> String.to_integer(port)
    end
  end

  defp get_config_listen_address do
    case Config.get(:mdns, :listen) do
      nil -> {0, 0, 0, 0}
      ip when is_tuple(ip) -> ip
      ip when is_binary(ip) -> String.to_charlist(ip) |> :inet.parse_ipv4_address() |> elem(1)
    end
  end
end