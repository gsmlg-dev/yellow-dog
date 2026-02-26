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

  # mDNS multicast address and port (RFC 6762)
  @mdns_multicast_address {224, 0, 0, 251}
  @mdns_port 5353
  # RFC 6762 §11: mDNS multicast TTL must be 255
  @mdns_multicast_ttl 255
  # RFC 6762 §17: mDNS messages should fit in a single packet
  @mdns_max_packet_size 1232

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
  Sends a multicast mDNS response.

  ## Parameters
  - `data` - Binary DNS message data to send

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec send_multicast(binary()) :: :ok | {:error, term()}
  def send_multicast(data) when is_binary(data) do
    GenServer.call(__MODULE__, {:send_multicast, data})
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
    mode = Keyword.get(opts, :mode, :hybrid)

    # Build transport options for multicast
    transport_options = build_transport_options(listen_address, multicast_address, opts)

    # Base abyss configuration
    [
      port: port,
      transport_module: Abyss.Transport.UDP.Broadcast,
      handler_module: handler_module,
      transport_options: transport_options,
      # Pass mode to handler
      handler_options: %{mode: mode},
      # mDNS-specific configuration
      read_timeout: Keyword.get(opts, :read_timeout, 5000),
      # Single listener for broadcast mode
      num_listeners: Keyword.get(opts, :num_listeners, 1),
      # mDNS MTU limit
      max_packet_size: Keyword.get(opts, :max_packet_size, @mdns_max_packet_size)
    ]
  end

  defp build_transport_options(listen_address, multicast_address, opts) do
    base_options = [
      {:ip, listen_address},
      {:multicast_if, listen_address},
      {:add_membership, {multicast_address, listen_address}},
      {:multicast_ttl, @mdns_multicast_ttl}
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
      handler_options: %{mode: :hybrid},
      transport_options: [
        ip: {0, 0, 0, 0},
        multicast_if: {0, 0, 0, 0},
        add_membership: {@mdns_multicast_address, {0, 0, 0, 0}},
        multicast_ttl: @mdns_multicast_ttl
      ],
      read_timeout: 5000,
      num_listeners: 1,
      max_packet_size: @mdns_max_packet_size
    ]
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    mode = Keyword.get(opts, :mode, :hybrid)
    Application.put_env(:yellow_dog_mdns, :mode, mode)

    try do
      server_config = build_server_config(opts)
      port = Keyword.get(server_config, :port, @mdns_port)
      multicast_address = Keyword.get(opts, :multicast_address, @mdns_multicast_address)

      :telemetry.execute(
        [:yellow_dog, :mdns, :server, :starting],
        %{count: 1},
        %{port: port, mode: mode}
      )

      case Abyss.start_link(server_config) do
        {:ok, abyss_pid} ->
          # Open a UDP socket for sending multicast responses
          socket_opts = [:binary, {:active, false}, {:reuseaddr, true}]
          {:ok, socket} = Abyss.Transport.UDP.open(0, socket_opts)

          :telemetry.execute(
            [:yellow_dog, :mdns, :server, :started],
            %{count: 1},
            %{port: port, mode: mode}
          )

          {:ok,
           %{
             abyss_pid: abyss_pid,
             config: server_config,
             socket: socket,
             multicast_address: multicast_address,
             port: port,
             mode: mode
           }}

        {:error, reason} ->
          :telemetry.execute(
            [:yellow_dog, :mdns, :server, :start_failed],
            %{count: 1},
            %{reason: inspect(reason)}
          )

          {:stop, reason}
      end
    rescue
      UndefinedFunctionError ->
        :telemetry.execute(
          [:yellow_dog, :mdns, :server, :config_fallback],
          %{count: 1},
          %{}
        )

        server_config = get_default_server_config()
        multicast_address = @mdns_multicast_address

        case Abyss.start_link(server_config) do
          {:ok, abyss_pid} ->
            {:ok, socket} = Abyss.Transport.UDP.open(0, active: false)

            {:ok,
             %{
               abyss_pid: abyss_pid,
               config: server_config,
               socket: socket,
               multicast_address: multicast_address,
               port: @mdns_port,
               mode: mode
             }}

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :mdns, :server, :start_failed],
              %{count: 1},
              %{reason: inspect(reason)}
            )

            {:stop, reason}
        end
    end
  end

  @impl true
  def handle_call({:send_multicast, data}, _from, state) do
    result =
      Abyss.Transport.UDP.send(
        state.socket,
        state.multicast_address,
        state.port,
        data
      )

    case result do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :mdns, :server, :multicast_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    :telemetry.execute(
      [:yellow_dog, :mdns, :server, :stopping],
      %{count: 1},
      %{reason: inspect(reason)}
    )

    if state[:socket] do
      Abyss.Transport.UDP.close(state.socket)
    end

    if state.abyss_pid, do: GenServer.stop(state.abyss_pid, :normal)
    :ok
  end
end
