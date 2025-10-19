defmodule YellowDog.Dhcpv6.Server do
  @moduledoc """
  DHCPv6 server implementation using Abyss UDP server library.

  Provides DHCPv6 service with support for SOLICIT, ADVERTISE, REQUEST,
  REPLY, and other DHCPv6 messages. Configuration is passed from the
  main YellowDog application.
  """

  use GenServer
  require Logger

  @doc """
  Starts the DHCPv6 server GenServer.

  ## Options
  - `port`: UDP port to listen on (default: 547 from config)
  - `listen`: IP address to bind to (default: "::" from config)
  - `multicast`: Enable multicast mode (default: true for DHCPv6)
  - Any other options are passed to Abyss

  ## Returns
  - `{:ok, pid}` - Server started successfully
  - `{:error, reason}` - Failed to start server
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stops the DHCPv6 server.
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
      port: 547,
      broadcast: true,
      handler_module: YellowDog.Dhcpv6.Handler,
      transport_options: [
        ip: "::",
        ipv6_v6only: true,
        reuseaddr: true
      ],
      read_timeout: 60_000,
      shutdown_timeout: 15_000,
      num_listeners: 10,
      num_connections: 1000,
      max_packet_size: 1500,  # DHCPv6 can use larger packets
      rate_limit_enabled: true,
      rate_limit_max_packets: 100,
      rate_limit_window_ms: 1000
    }
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    server_config = build_server_config(opts)
    port = Keyword.get(server_config, :port, 547)
    Logger.info("Starting DHCPv6 server on port #{port}")

    case Abyss.start_link(server_config) do
      {:ok, abyss_pid} ->
        {:ok, %{abyss_pid: abyss_pid, config: server_config}}

      {:error, reason} ->
        Logger.error("Failed to start DHCPv6 server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("DHCPv6 server stopping: #{inspect(reason)}")
    if state.abyss_pid, do: GenServer.stop(state.abyss_pid, :normal)
    :ok
  end

  # Private helper functions

  defp build_server_config(opts) do
    config = get_config()

    # Convert config map to keyword list for Keyword.merge
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

    # Override with provided options
    final_config =
      config_keywords
      |> Keyword.merge(opts_with_transport)
      |> Keyword.put(:handler_module, YellowDog.Dhcpv6.Handler)

    # Ensure broadcast mode is enabled for DHCPv6
    if Keyword.get(final_config, :broadcast, false) do
      final_config
    else
      Keyword.put(final_config, :broadcast, true)
    end
  end
end