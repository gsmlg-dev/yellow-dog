defmodule YellowDog.Dns.Server do
  @moduledoc """
  Network I/O server supervisor for DNS.

  Supervises the network servers:
  - `Abyss` - UDP server for DNS queries
  - `ThousandIsland` - TCP server for DNS queries

  This supervisor is a child of `YellowDog.Dns.Supervisor` and handles only
  network I/O. All DNS resolution logic is handled by ConnectionProcess,
  ViewManager, View, and Zone processes.

  ## Handler Registration

  - UDP: `YellowDog.Dns.Handler.UDP` is registered with Abyss
  - TCP: `YellowDog.Dns.Handler.TCP` is registered with ThousandIsland

  On each incoming packet/connection, handlers:
  1. Call ConnectionManager to start a connection process
  2. Forward queries to the connection process
  3. Send responses back to the client
  """

  use Supervisor

  alias YellowDog.Dns.IpFormat
  alias YellowDog.Telemetry

  @doc """
  Starts the network server supervisor.

  ## Options
  - `port`: UDP/TCP port to listen on (default: 53)
  - `listen`: IP address tuple to bind to
  - `tcp_enabled`: Whether to enable TCP server (default: true, can be configured via TOML)

  ## Returns
  - `{:ok, pid}` - Server started successfully
  - `{:error, reason}` - Failed to start server
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stops the server.
  """
  @spec stop(pid() | atom()) :: :ok
  def stop(pid \\ __MODULE__) do
    Supervisor.stop(pid)
  end

  @doc """
  Gets the default server configuration.
  """
  @spec get_config() :: map()
  def get_config do
    %{
      # Shared settings
      port: 53,
      listen: {0, 0, 0, 0},

      # TCP enabled flag (can be disabled via config)
      tcp_enabled: true,

      # UDP settings (Abyss)
      udp: %{
        transport_module: Abyss.Transport.UDP.Unicast,
        handler_module: YellowDog.Dns.Handler.UDP,
        transport_options: [
          ip: {0, 0, 0, 0},
          reuseaddr: true
        ],
        read_timeout: 5_000,
        shutdown_timeout: 5_000,
        num_listeners: 50,
        num_connections: 10_000,
        max_packet_size: 512
      },

      # TCP settings (ThousandIsland)
      tcp: %{
        handler_module: YellowDog.Dns.Handler.TCP,
        transport_module: ThousandIsland.Transports.TCP,
        transport_options: [
          ip: {0, 0, 0, 0},
          reuseaddr: true,
          nodelay: true
        ],
        num_acceptors: 100,
        num_connections: 16_384,
        read_timeout: 120_000,
        shutdown_timeout: 15_000
      }
    }
  end

  @doc """
  Returns server status.
  """
  @spec status() :: map()
  def status do
    tcp_enabled = get_tcp_enabled()

    %{
      running: Process.whereis(__MODULE__) != nil,
      udp: %{running: find_abyss_pid(__MODULE__) != nil},
      tcp: %{
        enabled: tcp_enabled,
        running: tcp_enabled and find_thousand_island_pid(__MODULE__) != nil
      }
    }
  end

  @doc """
  Returns whether TCP is enabled.
  """
  @spec tcp_enabled?() :: boolean()
  def tcp_enabled? do
    get_tcp_enabled()
  end

  @doc """
  Returns the UDP port the server is listening on.

  Useful for tests when starting with port 0 (auto-select).
  """
  @spec get_port() :: {:ok, :inet.port_number()} | {:error, term()}
  def get_port, do: get_udp_port(__MODULE__)

  @spec get_port(pid() | atom()) :: {:ok, :inet.port_number()} | {:error, term()}
  def get_port(pid), do: get_udp_port(pid)

  @doc """
  Returns the UDP port the server is listening on.
  """
  @spec get_udp_port() :: {:ok, :inet.port_number()} | {:error, term()}
  def get_udp_port, do: get_udp_port(__MODULE__)

  @spec get_udp_port(pid() | atom()) :: {:ok, :inet.port_number()} | {:error, term()}
  def get_udp_port(supervisor) do
    # Use cached lookup to avoid GenServer call timeout when listener is blocked in recv
    with {:abyss, abyss_pid} when abyss_pid != nil <-
           {:abyss, find_abyss_pid(supervisor)},
         {:pool, pool_pid} when pool_pid != nil <-
           {:pool, Abyss.Server.listener_pool_pid(abyss_pid)},
         [listener_pid | _] <- Abyss.ListenerPool.listener_pids(pool_pid),
         {:ok, {_ip, port}} when is_integer(port) <-
           Abyss.Listener.listener_info_cached(listener_pid) do
      {:ok, port}
    else
      {:abyss, nil} -> {:error, :abyss_not_found}
      {:pool, nil} -> {:error, :no_listener_pool}
      [] -> {:error, :no_listeners}
      {:ok, _} -> {:error, :invalid_listener_info}
      :error -> {:error, :listener_info_not_cached}
    end
  end

  @doc """
  Returns the TCP port the server is listening on.
  """
  @spec get_tcp_port() :: {:ok, :inet.port_number()} | {:error, term()}
  def get_tcp_port, do: get_tcp_port(__MODULE__)

  @spec get_tcp_port(pid() | atom()) :: {:ok, :inet.port_number()} | {:error, term()}
  def get_tcp_port(supervisor) do
    with ti_pid when ti_pid != nil <- find_thousand_island_pid(supervisor),
         {:ok, {_ip, port}} when is_integer(port) <- ThousandIsland.listener_info(ti_pid) do
      {:ok, port}
    else
      nil -> {:error, :thousand_island_not_found}
      {:ok, _} -> {:error, :invalid_listener_info}
      :error -> {:error, :port_not_available}
    end
  end

  # Supervisor callbacks

  @impl true
  def init(opts) do
    Telemetry.info("Starting DNS network server")

    # Build configurations
    abyss_config = build_abyss_config(opts)

    port = Keyword.get(opts, :port, 53)
    listen = Keyword.get(opts, :listen, {0, 0, 0, 0})
    listen_ip = normalize_ip(listen)

    # Check if TCP is enabled
    tcp_enabled = Keyword.get(opts, :tcp_enabled, get_tcp_enabled())

    Telemetry.info("DNS server listening", %{
      port: port,
      listen: IpFormat.format(listen_ip),
      udp: true,
      tcp: tcp_enabled
    })

    # Always start UDP server
    children = [
      %{
        id: :abyss,
        start: {Abyss, :start_link, [abyss_config]},
        restart: :permanent,
        type: :supervisor
      }
    ]

    # Conditionally add TCP server
    children =
      if tcp_enabled do
        tcp_config = build_thousand_island_config(opts)

        children ++
          [
            %{
              id: :thousand_island,
              start: {ThousandIsland, :start_link, [tcp_config]},
              restart: :permanent,
              type: :supervisor
            }
          ]
      else
        Telemetry.info("DNS TCP server disabled by configuration")
        children
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private helpers

  defp get_tcp_enabled do
    # Check config for tcp_enabled setting, default to true
    case apply(YellowDog.Config, :get, [:dns, :tcp_enabled]) do
      nil -> true
      enabled when is_boolean(enabled) -> enabled
      "true" -> true
      "false" -> false
      _ -> true
    end
  rescue
    _e in [ArgumentError, UndefinedFunctionError] -> true
  end

  defp find_abyss_pid(supervisor) do
    pid = resolve_pid(supervisor)

    case pid do
      nil ->
        nil

      _ ->
        children = Supervisor.which_children(pid)

        Enum.find_value(children, fn
          {:abyss, child_pid, :supervisor, _} when is_pid(child_pid) -> child_pid
          _ -> nil
        end)
    end
  rescue
    _e in [ArgumentError, RuntimeError] -> nil
  end

  defp find_thousand_island_pid(supervisor) do
    pid = resolve_pid(supervisor)

    case pid do
      nil ->
        nil

      _ ->
        children = Supervisor.which_children(pid)

        Enum.find_value(children, fn
          {:thousand_island, child_pid, :supervisor, _} when is_pid(child_pid) -> child_pid
          _ -> nil
        end)
    end
  rescue
    _e in [ArgumentError, RuntimeError] -> nil
  end

  defp resolve_pid(supervisor) do
    cond do
      is_pid(supervisor) -> supervisor
      is_atom(supervisor) -> Process.whereis(supervisor)
      true -> nil
    end
  end

  defp build_abyss_config(opts) do
    config = get_config()
    udp_config = config.udp

    port = Keyword.get(opts, :port, config.port)
    listen_ip = normalize_ip(Keyword.get(opts, :listen, config.listen))

    transport_options =
      udp_config.transport_options
      |> Keyword.put(:ip, listen_ip)

    [
      port: port,
      transport_module: udp_config.transport_module,
      handler_module: udp_config.handler_module,
      transport_options: transport_options,
      read_timeout: udp_config.read_timeout,
      shutdown_timeout: udp_config.shutdown_timeout,
      num_listeners: udp_config.num_listeners,
      num_connections: udp_config.num_connections,
      max_packet_size: udp_config.max_packet_size
    ]
  end

  defp build_thousand_island_config(opts) do
    config = get_config()
    tcp_config = config.tcp

    port = Keyword.get(opts, :port, config.port)
    listen_ip = normalize_ip(Keyword.get(opts, :listen, config.listen))

    transport_options =
      tcp_config.transport_options
      |> Keyword.put(:ip, listen_ip)

    [
      port: port,
      handler_module: tcp_config.handler_module,
      transport_module: tcp_config.transport_module,
      transport_options: transport_options,
      num_acceptors: tcp_config.num_acceptors,
      num_connections: tcp_config.num_connections,
      read_timeout: tcp_config.read_timeout,
      shutdown_timeout: tcp_config.shutdown_timeout
    ]
  end

  defp normalize_ip(ip) when is_tuple(ip), do: ip

  defp normalize_ip(ip_str) when is_binary(ip_str) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, ip} -> ip
      {:error, _} -> {0, 0, 0, 0}
    end
  end

  defp normalize_ip(_), do: {0, 0, 0, 0}
end
