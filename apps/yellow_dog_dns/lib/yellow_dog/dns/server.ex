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

  alias YellowDog.Telemetry

  @doc """
  Starts the network server supervisor.

  ## Options
  - `port`: UDP/TCP port to listen on (default: 53)
  - `listen`: IP address tuple to bind to

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
        max_packet_size: 512,
        rate_limit_enabled: true,
        rate_limit_max_packets: 1000,
        rate_limit_window_ms: 1000
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
    %{
      running: Process.whereis(__MODULE__) != nil,
      udp: %{running: find_abyss_pid(__MODULE__) != nil},
      tcp: %{running: find_thousand_island_pid(__MODULE__) != nil}
    }
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
    case find_abyss_pid(supervisor) do
      nil ->
        {:error, :abyss_not_found}

      abyss_pid ->
        case Abyss.Server.listener_pool_pid(abyss_pid) do
          nil ->
            {:error, :no_listener_pool}

          pool_pid ->
            case Abyss.ListenerPool.listener_pids(pool_pid) do
              [] ->
                {:error, :no_listeners}

              [listener_pid | _] ->
                case Abyss.Listener.listener_info(listener_pid) do
                  {_ip, port} when is_integer(port) -> {:ok, port}
                  _ -> {:error, :invalid_listener_info}
                end
            end
        end
    end
  end

  @doc """
  Returns the TCP port the server is listening on.
  """
  @spec get_tcp_port() :: {:ok, :inet.port_number()} | {:error, term()}
  def get_tcp_port, do: get_tcp_port(__MODULE__)

  @spec get_tcp_port(pid() | atom()) :: {:ok, :inet.port_number()} | {:error, term()}
  def get_tcp_port(supervisor) do
    case find_thousand_island_pid(supervisor) do
      nil ->
        {:error, :thousand_island_not_found}

      ti_pid ->
        # ThousandIsland stores port in its state
        case ThousandIsland.listener_info(ti_pid) do
          {:ok, info} -> {:ok, info.port}
          :error -> {:error, :port_not_available}
        end
    end
  end

  # Supervisor callbacks

  @impl true
  def init(opts) do
    Telemetry.info("Starting DNS network server")

    # Build configurations
    abyss_config = build_abyss_config(opts)
    tcp_config = build_thousand_island_config(opts)

    port = Keyword.get(opts, :port, 53)
    listen = Keyword.get(opts, :listen, {0, 0, 0, 0})
    listen_ip = normalize_ip(listen)

    Telemetry.info("DNS server listening", %{
      port: port,
      listen: format_ip(listen_ip),
      udp: true,
      tcp: true
    })

    children = [
      # Abyss UDP server
      %{
        id: :abyss,
        start: {Abyss, :start_link, [abyss_config]},
        restart: :permanent,
        type: :supervisor
      },
      # ThousandIsland TCP server
      %{
        id: :thousand_island,
        start: {ThousandIsland, :start_link, [tcp_config]},
        restart: :permanent,
        type: :supervisor
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private helpers

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
    _ -> nil
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
    _ -> nil
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
      max_packet_size: udp_config.max_packet_size,
      rate_limit_enabled: udp_config.rate_limit_enabled,
      rate_limit_max_packets: udp_config.rate_limit_max_packets,
      rate_limit_window_ms: udp_config.rate_limit_window_ms
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
    charlist = String.to_charlist(ip_str)

    case :inet.parse_ipv4_address(charlist) do
      {:ok, ip} ->
        ip

      {:error, _} ->
        case :inet.parse_ipv6_address(charlist) do
          {:ok, ip} -> ip
          {:error, _} -> {0, 0, 0, 0}
        end
    end
  end

  defp normalize_ip(_), do: {0, 0, 0, 0}

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
    Enum.join(hex_parts, ":")
  end

  defp format_ip(other), do: inspect(other)
end
