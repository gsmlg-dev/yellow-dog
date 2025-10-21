defmodule YellowDog.Dns.Server do
  @moduledoc """
  DNS server implementation using Abyss UDP server library.

  Provides DNS service with support for standard DNS queries (A, AAAA, MX,
  NS, SOA, TXT, CNAME, etc.). Configuration is loaded from YellowDog.Config.
  """

  use GenServer

  alias YellowDog.Telemetry

  @doc """
  Starts the DNS server GenServer.

  ## Options
  - `port`: UDP port to listen on (overrides config)
  - `listen`: IP address to bind to (overrides config)
  - Any other options are passed to Abyss

  ## Returns
  - `{:ok, pid}` - Server started successfully
  - `{:error, reason}` - Failed to start server
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stops the DNS server.
  """
  def stop(pid \\ __MODULE__) do
    GenServer.stop(pid)
  end

  @doc """
  Gets the default server configuration.

  This should only be used for testing. In production, configuration
  is loaded from YellowDog.Config.
  """
  def get_config do
    %{
      port: 53,
      broadcast: false,
      handler_module: YellowDog.Dns.Handler.UDP,
      transport_options: [
        ip: {0, 0, 0, 0},
        reuseaddr: true
      ],
      read_timeout: 5_000,
      shutdown_timeout: 5_000,
      num_listeners: 50,
      num_connections: 10_000,
      max_packet_size: 512,  # DNS UDP limit
      rate_limit_enabled: true,
      rate_limit_max_packets: 1000,
      rate_limit_window_ms: 1000
    }
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    Telemetry.span("dns.server.init", %{}, fn ->
      server_config = build_server_config(opts)
      port = Keyword.get(server_config, :port, 53)
      transport_opts = Keyword.get(server_config, :transport_options, [])
      listen_ip = Keyword.get(transport_opts, :ip, {0, 0, 0, 0})

      Telemetry.info("Starting DNS server", %{
        port: port,
        listen: format_ip(listen_ip)
      })

      case Abyss.start_link(server_config) do
        {:ok, abyss_pid} ->
          Telemetry.info("DNS server started successfully", %{
            port: port,
            pid: inspect(abyss_pid)
          })
          {:ok, %{abyss_pid: abyss_pid, config: server_config}}

        {:error, reason} ->
          Telemetry.error("Failed to start DNS server", %{
            error: inspect(reason),
            port: port
          })
          {:stop, reason}
      end
    end)
  end

  @impl true
  def terminate(reason, state) do
    Telemetry.info("DNS server stopping", %{reason: inspect(reason)})
    if state.abyss_pid, do: GenServer.stop(state.abyss_pid, :normal)
    :ok
  end

  # Private helper functions

  defp build_server_config(opts) do
    # Start with defaults
    config = get_config()

    # Get configuration from YellowDog.Config
    port = YellowDog.Config.get(:dns, :port, config.port)
    listen = YellowDog.Config.get(:dns, :listen, "0.0.0.0")

    # Convert listen IP string to tuple format
    listen_ip = case parse_ip(listen) do
      {:ok, ip} -> ip
      {:error, _} ->
        Telemetry.warning("Invalid listen IP, using default", %{listen: listen})
        {0, 0, 0, 0}
    end

    # Build config with YellowDog config values
    config_keywords =
      config
      |> Map.put(:port, port)
      |> Map.update!(:transport_options, fn transport_opts ->
        Keyword.put(transport_opts, :ip, listen_ip)
      end)
      |> Enum.map(fn {key, value} -> {key, value} end)

    # Handle special case for listen option from opts - move it to transport_options
    {config_keywords, opts_with_transport} =
      case Keyword.get(opts, :listen) do
        nil ->
          {config_keywords, opts}
        listen_opt ->
          case parse_ip(listen_opt) do
            {:ok, ip} ->
              transport_opts = Keyword.get(config_keywords, :transport_options, [])
              updated_transport_opts = Keyword.put(transport_opts, :ip, ip)
              updated_keywords = Keyword.put(config_keywords, :transport_options, updated_transport_opts)
              {updated_keywords, Keyword.delete(opts, :listen)}
            {:error, _} ->
              Telemetry.warning("Invalid listen IP in opts, ignoring", %{listen: listen_opt})
              {config_keywords, Keyword.delete(opts, :listen)}
          end
      end

    # Override with provided options
    final_config =
      config_keywords
      |> Keyword.merge(opts_with_transport)
      |> Keyword.put(:handler_module, YellowDog.Dns.Handler.UDP)

    final_config
  end

  defp parse_ip(ip_str) when is_binary(ip_str) do
    charlist = String.to_charlist(ip_str)

    case :inet.parse_ipv4_address(charlist) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} ->
        case :inet.parse_ipv6_address(charlist) do
          {:ok, ip} -> {:ok, ip}
          {:error, _} -> {:error, :invalid_ip}
        end
    end
  end

  defp parse_ip(ip) when is_tuple(ip), do: {:ok, ip}
  defp parse_ip(_), do: {:error, :invalid_ip}

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
    Enum.join(hex_parts, ":")
  end
  defp format_ip(other), do: inspect(other)
end