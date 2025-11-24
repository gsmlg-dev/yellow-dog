defmodule Abyss do
  @moduledoc """
  Abyss is a modern, pure Elixir UDP socket server library.

  It provides a high-performance foundation for building UDP-based services
  like DNS servers, DHCP servers, or custom UDP applications. Abyss implements
  a supervisor-based architecture with connection pooling and pluggable transport
  modules.

  ## Features

  - **High Performance**: Supervisor-based architecture with configurable connection pooling
  - **Flexible Handler System**: Pluggable handler modules for custom protocol implementations
  - **Real-time Metrics**: Built-in telemetry with connection counts, throughput rates, and response times
  - **Security Features**: Built-in rate limiting and packet size validation
  - **Broadcast Support**: Native support for broadcast and multicast applications
  - **Graceful Shutdown**: Coordinated shutdown with configurable timeouts
  - **Extensible Transport**: Pluggable transport layer (currently UDP)

  ## Quick Start

      defmodule MyHandler do
        use Abyss.Handler

        @impl true
        def handle_data({ip, port, data}, state) do
          # Echo the data back to the client
          Abyss.Transport.UDP.send(state.socket, ip, port, data)
          {:continue, state}
        end
      end

      # Start the server
      {:ok, _pid} = Abyss.start_link([
        handler_module: MyHandler,
        port: 1234,
        num_listeners: 10
      ])

      # Monitor server metrics
      metrics = Abyss.Telemetry.get_metrics()
      IO.inspect(metrics, label: "Server Metrics")

  ## Telemetry and Monitoring

  Abyss provides built-in telemetry metrics for real-time monitoring:

      # Get current metrics
      metrics = Abyss.Telemetry.get_metrics()
      # => %{
      #   connections_active: 5,
      #   connections_total: 150,
      #   accepts_total: 150,
      #   responses_total: 145,
      #   accepts_per_second: 12,
      #   responses_per_second: 11
      # }

      # Listen for response time events
      :telemetry.attach_many(
        "response-monitor",
        [[:abyss, :metrics, :response_time]],
        fn [:abyss, :metrics, :response_time], measurements, _metadata, _config ->
          IO.puts("Response time: \#{measurements.response_time}ms")
        end,
        %{}
      )

  ### Available Metrics

  - **`connections_active`**: Number of currently active connections
  - **`connections_total`**: Total connections since server start
  - **`accepts_total`**: Total accepted connections
  - **`responses_total`**: Total responses sent
  - **`accepts_per_second`**: Current accepts per second rate
  - **`responses_per_second`**: Current responses per second rate

  For detailed monitoring options and telemetry events, see the `Abyss.Telemetry` module documentation.
  """

  @typedoc """
  Configuration options for starting an Abyss server.

  ## Required Options

  - `handler_module` - Module implementing `Abyss.Handler` behaviour

  ## Optional Options

  - `handler_options` - Options passed to handler module (default: `[]`)
  - `genserver_options` - GenServer options for handler processes (default: `[]`)
  - `supervisor_options` - Supervisor options (default: `[]`)
  - `port` - UDP port to listen on (default: `4000`)
  - `transport_module` - Transport module (default: `Abyss.Transport.UDP`)
  - `transport_options` - Options passed to transport module (default: `[]`)
  - `num_acceptors` - Number of acceptor processes (deprecated, use `num_listeners`)
  - `num_listeners` - Number of listener processes (default: `100`)
  - `num_connections` - Max concurrent connections (default: `16_384`)
  - `max_connections_retry_count` - Connection retry attempts (default: `5`)
  - `max_connections_retry_wait` - Retry wait time in ms (default: `1000`)
  - `read_timeout` - Connection read timeout in ms (default: `60_000`)
  - `shutdown_timeout` - Graceful shutdown timeout in ms (default: `15_000`)
  - `silent_terminate_on_error` - Silent termination on errors (default: `false`)
  - `rate_limit_enabled` - Enable rate limiting (default: `false`)
  - `rate_limit_max_packets` - Max packets per rate limit window (default: `1000`)
  - `rate_limit_window_ms` - Rate limit window in ms (default: `1000`)
  - `max_packet_size` - Maximum packet size in bytes (default: `8192`)
  """
  @type options :: [
          handler_module: module(),
          handler_options: term(),
          genserver_options: GenServer.options(),
          supervisor_options: [Supervisor.option()],
          port: :inet.port_number(),
          transport_module: module(),
          transport_options: transport_options(),
          num_acceptors: pos_integer(),
          num_connections: non_neg_integer() | :infinity,
          max_connections_retry_count: non_neg_integer(),
          max_connections_retry_wait: timeout(),
          read_timeout: timeout(),
          shutdown_timeout: timeout(),
          silent_terminate_on_error: boolean(),
          rate_limit_enabled: boolean(),
          rate_limit_max_packets: pos_integer(),
          rate_limit_window_ms: pos_integer(),
          max_packet_size: pos_integer()
        ]

  @typedoc "A module implementing `Abyss.Transport` behaviour"
  @type transport_module :: Abyss.Transport.UDP

  @typedoc "A keyword list of options to be passed to the transport module's `listen/2` function"
  @type transport_options() :: Abyss.Transport.listen_options()

  @doc false
  @spec child_spec(options()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Starts a `Abyss` instance with the given options. Returns a pid
  that can be used to further manipulate the server via other functions defined on
  this module in the case of success, or an error tuple describing the reason the
  server was unable to start in the case of failure.
  """
  @spec start_link(options()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    opts
    |> Abyss.ServerConfig.new()
    |> Abyss.Server.start_link()
  end

  @doc """
  Suspend the server. This will close the listening port, and will stop the acceptance of new
  connections. Existing connections will stay connected and will continue to be processed.

  The server can later be resumed by calling `resume/1`, or shut down via standard supervision
  patterns.

  If this function returns `:error`, it is unlikely that the server is in a useable state

  Note that if you do not explicitly set a port (or if you set port to `0`), then the server will
  bind to a different port when you resume it. This new port can be obtained as usual via the
  `listener_info/1` function. This is not a concern if you explicitly set a port value when first
  instantiating the server
  """
  defdelegate suspend(supervisor), to: Abyss.Server

  @doc """
  Resume a suspended server. This will reopen the listening port, and resume the acceptance of new
  connections
  """
  defdelegate resume(supervisor), to: Abyss.Server

  @doc """
  Synchronously stops the given server, waiting up to the given number of milliseconds
  for existing connections to finish up. Immediately upon calling this function,
  the server stops listening for new connections, and then proceeds to wait until
  either all existing connections have completed or the specified timeout has
  elapsed.
  """
  @spec stop(Supervisor.supervisor(), timeout()) :: :ok
  def stop(supervisor, connection_wait \\ 15_000) do
    Supervisor.stop(supervisor, :normal, connection_wait)
  end
end
