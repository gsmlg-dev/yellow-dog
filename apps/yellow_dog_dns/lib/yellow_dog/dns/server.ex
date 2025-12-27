defmodule YellowDog.Dns.Server do
  @moduledoc """
  Network I/O server supervisor for DNS.

  Supervises the network servers:
  - `Abyss` - UDP server for DNS queries
  - `ThousandIsland` - TCP server for DNS queries (TODO: implement)

  This supervisor is a child of `YellowDog.Dns.Supervisor` and handles only
  network I/O. All DNS resolution logic is handled by ConnectionProcess,
  ViewManager, View, and Zone processes.

  ## Handler Registration

  The handler module (`YellowDog.Dns.Handler.UDP`) is registered with Abyss.
  On each incoming packet, the handler:
  1. Calls ConnectionManager to start a connection process
  2. Forwards queries to the connection process
  3. Sends responses back to the client
  """

  use Supervisor

  alias YellowDog.Telemetry

  @doc """
  Starts the network server supervisor.

  ## Options
  - `port`: UDP port to listen on (default: 53)
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
      port: 53,
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
      tcp: %{running: false}  # TODO: implement TCP
    }
  end

  @doc """
  Returns the UDP port the server is listening on.

  Useful for tests when starting with port 0 (auto-select).
  """
  @spec get_port() :: {:ok, :inet.port_number()} | {:error, term()}
  def get_port, do: get_port(__MODULE__)

  @spec get_port(pid() | atom()) :: {:ok, :inet.port_number()} | {:error, term()}
  def get_port(pid) do
    case find_abyss_pid(pid) do
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

  # Supervisor callbacks

  @impl true
  def init(opts) do
    Telemetry.info("Starting DNS network server")

    # Build Abyss configuration
    abyss_config = build_abyss_config(opts)
    port = Keyword.get(abyss_config, :port, 53)
    transport_opts = Keyword.get(abyss_config, :transport_options, [])
    listen_ip = Keyword.get(transport_opts, :ip, {0, 0, 0, 0})

    Telemetry.info("DNS server listening", %{
      port: port,
      listen: format_ip(listen_ip)
    })

    children = [
      # Abyss UDP server
      %{
        id: :abyss,
        start: {Abyss, :start_link, [abyss_config]},
        restart: :permanent,
        type: :supervisor
      }
      # TODO: Add ThousandIsland TCP server
      # %{
      #   id: :thousand_island,
      #   start: {ThousandIsland, :start_link, [tcp_config]},
      #   restart: :permanent,
      #   type: :supervisor
      # }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private helpers

  defp find_abyss_pid(supervisor_pid) do
    case Process.whereis(supervisor_pid) do
      nil ->
        nil

      pid when is_pid(pid) ->
        children = Supervisor.which_children(pid)

        Enum.find_value(children, fn
          {:abyss, child_pid, :supervisor, _} when is_pid(child_pid) -> child_pid
          _ -> nil
        end)
    end
  rescue
    _ -> nil
  end

  defp build_abyss_config(opts) do
    config = get_config()

    port = Keyword.get(opts, :port, config.port)
    listen = Keyword.get(opts, :listen, {0, 0, 0, 0})

    listen_ip =
      case listen do
        ip when is_tuple(ip) -> ip
        ip_str when is_binary(ip_str) -> parse_ip(ip_str)
        _ -> {0, 0, 0, 0}
      end

    transport_options =
      config.transport_options
      |> Keyword.put(:ip, listen_ip)

    config
    |> Map.to_list()
    |> Keyword.put(:port, port)
    |> Keyword.put(:transport_options, transport_options)
    |> Keyword.put(:handler_module, YellowDog.Dns.Handler.UDP)
  end

  defp parse_ip(ip_str) when is_binary(ip_str) do
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

  defp parse_ip(ip) when is_tuple(ip), do: ip
  defp parse_ip(_), do: {0, 0, 0, 0}

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
    Enum.join(hex_parts, ":")
  end

  defp format_ip(other), do: inspect(other)
end
