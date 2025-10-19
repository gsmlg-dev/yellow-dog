defmodule YellowDog.Dns.Server do
  @moduledoc """
  DNS server implementation using Abyss UDP server library.

  Provides DNS service with support for standard DNS queries (A, AAAA, MX,
  NS, SOA, TXT, CNAME, etc.). Configuration is passed from the main
  YellowDog application.
  """

  use GenServer
  require Logger

  @doc """
  Starts the DNS server GenServer.

  ## Options
  - `port`: UDP port to listen on (default: 53 from config)
  - `listen`: IP address to bind to (default: "0.0.0.0" from config)
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
  Gets the current server configuration using defaults.

  This should only be used for testing. In production, configuration
  should be passed from the main YellowDog application.
  """
  def get_config do
    %{
      port: 53,
      broadcast: false,
      handler_module: YellowDog.Dns.Handler.UDP,
      transport_options: [
        ip: "0.0.0.0",
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
    server_config = build_server_config(opts)
    port = Keyword.get(server_config, :port, 53)
    Logger.info("Starting DNS server on port #{port}")

    case Abyss.start_link(server_config) do
      {:ok, abyss_pid} ->
        {:ok, %{abyss_pid: abyss_pid, config: server_config}}

      {:error, reason} ->
        Logger.error("Failed to start DNS server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("DNS server stopping: #{inspect(reason)}")
    if state.abyss_pid, do: GenServer.stop(state.abyss_pid, :normal)
    :ok
  end

  # Private helper functions

  defp build_server_config(opts) do
    # Start with defaults, then override with passed options
    config = get_config()

    # Convert defaults to keyword list
    config_keywords =
      config
      |> Enum.map(fn {key, value} -> {key, value} end)

    # Handle special case for listen option - move it to transport_options
    {config_keywords, opts_with_transport} =
      case Keyword.get(opts, :listen) do
        nil ->
          {config_keywords, opts}
        listen_ip ->
          transport_opts = Keyword.get(config_keywords, :transport_options, [])
          updated_transport_opts = Keyword.put(transport_opts, :ip, listen_ip)
          updated_keywords = Keyword.put(config_keywords, :transport_options, updated_transport_opts)
          {updated_keywords, Keyword.delete(opts, :listen)}
      end

    # Override with provided options (from main YellowDog app)
    final_config =
      config_keywords
      |> Keyword.merge(opts_with_transport)
      |> Keyword.put(:handler_module, YellowDog.Dns.Handler.UDP)

    final_config
  end
end