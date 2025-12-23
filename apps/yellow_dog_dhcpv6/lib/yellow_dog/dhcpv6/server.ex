defmodule YellowDog.Dhcpv6.Server do
  @moduledoc """
  DHCPv6 server implementation using Abyss UDP server library.

  Provides DHCPv6 service with support for SOLICIT, ADVERTISE, REQUEST,
  REPLY, and other DHCPv6 messages. Configuration is passed from the
  main YellowDog application.
  """

  use GenServer

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
      transport_module: Abyss.Transport.UDP.Broadcast,
      handler_module: YellowDog.Dhcpv6.Handler,
      transport_options: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        ipv6_v6only: true,
        reuseaddr: true
      ],
      read_timeout: 60_000,
      shutdown_timeout: 15_000,
      num_listeners: 10,
      num_connections: 1000,
      # DHCPv6 can use larger packets
      max_packet_size: 1500,
      # Rate limiting disabled - Abyss.RateLimiter uses a global name and conflicts
      # with other services. DHCP runs on trusted internal networks anyway.
      rate_limit_enabled: false,
      rate_limit_max_packets: 100,
      rate_limit_window_ms: 1000
    }
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    server_config = build_server_config(opts)
    port = Keyword.get(server_config, :port, 547)

    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :server, :starting],
      %{count: 1},
      %{port: port}
    )

    case Abyss.start_link(server_config) do
      {:ok, abyss_pid} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :server, :started],
          %{count: 1},
          %{port: port}
        )

        {:ok, %{abyss_pid: abyss_pid, config: server_config}}

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :server, :start_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:stop, reason}
    end
  end

  @impl true
  def terminate(reason, state) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :server, :stopping],
      %{count: 1},
      %{reason: inspect(reason)}
    )

    if state.abyss_pid, do: GenServer.stop(state.abyss_pid, :normal)
    :ok
  end

  # Private helper functions

  # DHCP-specific options that should not be passed to Abyss
  @dhcp_specific_keys [:pools, :static_reservations]

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

          updated_keywords =
            Keyword.put(config_keywords, :transport_options, updated_transport_opts)

          {updated_keywords, Keyword.delete(opts, :listen)}
      end

    # Filter out DHCP-specific options that Abyss doesn't understand
    abyss_opts = Keyword.drop(opts_with_transport, @dhcp_specific_keys)

    # Override with provided options
    # IMPORTANT: Force rate_limit_enabled: false at the end to avoid conflicts
    # with the global Abyss.RateLimiter process
    final_config =
      config_keywords
      |> Keyword.merge(abyss_opts)
      |> Keyword.put(:handler_module, YellowDog.Dhcpv6.Handler)
      |> Keyword.put(:transport_module, Abyss.Transport.UDP.Broadcast)
      |> Keyword.put(:rate_limit_enabled, false)

    final_config
  end
end
