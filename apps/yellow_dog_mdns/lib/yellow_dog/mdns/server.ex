defmodule YellowDog.Mdns.Server do
  @moduledoc """
  mDNS server implementation using Abyss UDP server library.

  Provides multicast DNS functionality with proper socket configuration
  for mDNS multicast address (224.0.0.251:5353). Configuration is
  passed from the main YellowDog application.
  """

  use GenServer
  require Logger

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
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stops the mDNS server.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Gets the current server configuration using defaults.

  This should only be used for testing. In production, configuration
  should be passed from the main YellowDog application.
  """
  @spec get_config() :: server_config()
  def get_config do
    %{
      port: @mdns_port,
      listen_address: {0, 0, 0, 0},
      multicast_address: @mdns_multicast_address
    }
  end

  # Private functions

  defp build_server_config(opts) do
    port = Keyword.get(opts, :port, @mdns_port)
    listen_address = Keyword.get(opts, :listen_address, {0, 0, 0, 0})
    handler_module = Keyword.get(opts, :handler_module, YellowDog.Mdns.Handler)
    multicast_address = Keyword.get(opts, :multicast_address, @mdns_multicast_address)

    # Build transport options for multicast
    transport_options = build_transport_options(listen_address, multicast_address, opts)

    # Base abyss configuration
    [
      port: port,
      transport_module: Abyss.Transport.UDP.Broadcast,
      handler_module: handler_module,
      transport_options: transport_options,
      # mDNS-specific configuration
      read_timeout: Keyword.get(opts, :read_timeout, 5000),
      # Single listener for broadcast mode
      num_listeners: Keyword.get(opts, :num_listeners, 1),
      # Disabled for local mDNS
      rate_limit_enabled: Keyword.get(opts, :rate_limit_enabled, false),
      # mDNS MTU limit
      max_packet_size: Keyword.get(opts, :max_packet_size, 1232)
    ]
  end

  defp build_transport_options(listen_address, multicast_address, opts) do
    base_options = [
      {:ip, listen_address},
      {:multicast_if, listen_address},
      {:add_membership, {multicast_address, listen_address}},
      # mDNS uses TTL 255
      {:multicast_ttl, 255}
    ]

    # Add any additional transport options from opts
    additional_opts = Keyword.get(opts, :transport_options, [])

    base_options ++ additional_opts
  end

  defp get_default_server_config do
    [
      port: @mdns_port,
      transport_module: Abyss.Transport.UDP.Broadcast,
      handler_module: YellowDog.Mdns.Handler,
      transport_options: [
        ip: {0, 0, 0, 0},
        multicast_if: {0, 0, 0, 0},
        add_membership: {@mdns_multicast_address, {0, 0, 0, 0}},
        multicast_ttl: 255
      ],
      read_timeout: 5000,
      num_listeners: 1,
      rate_limit_enabled: false,
      max_packet_size: 1232
    ]
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    try do
      server_config = build_server_config(opts)
      port = Keyword.get(server_config, :port, 5353)
      Logger.info("Starting mDNS server on port #{port}")

      case Abyss.start_link(server_config) do
        {:ok, abyss_pid} ->
          {:ok, %{abyss_pid: abyss_pid, config: server_config}}

        {:error, reason} ->
          Logger.error("Failed to start mDNS server: #{inspect(reason)}")
          {:stop, reason}
      end
    rescue
      UndefinedFunctionError ->
        Logger.warning("Config module not available in test environment, using defaults")
        server_config = get_default_server_config()

        case Abyss.start_link(server_config) do
          {:ok, abyss_pid} ->
            {:ok, %{abyss_pid: abyss_pid, config: server_config}}

          {:error, reason} ->
            Logger.error("Failed to start mDNS server: #{inspect(reason)}")
            {:stop, reason}
        end
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("mDNS server stopping: #{inspect(reason)}")
    if state.abyss_pid, do: GenServer.stop(state.abyss_pid, :normal)
    :ok
  end
end
