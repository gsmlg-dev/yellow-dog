defmodule YellowDog.Dhcpv4.Server do
  @moduledoc """
  DHCPv4 server implementation using Abyss UDP server library.

  Provides DHCPv4 service with support for DHCPDISCOVER, DHCPOFFER,
  DHCPREQUEST, DHCPACK, and DHCPNAK messages. Configuration is
  passed from the main YellowDog application.
  """

  use GenServer

  @doc """
  Starts the DHCPv4 server GenServer.

  ## Options
  - `port`: UDP port to listen on (default: 67 from config)
  - `listen`: IP address to bind to (default: "0.0.0.0" from config)
  - `broadcast`: Enable broadcast mode (default: true for DHCP)
  - Any other options are passed to Abyss

  ## Returns
  - `{:ok, pid}` - Server started successfully
  - `{:error, reason}` - Failed to start server
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stops the DHCPv4 server.
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
      port: 67,
      transport_module: Abyss.Transport.UDP.Broadcast,
      handler_module: YellowDog.Dhcpv4.Handler,
      transport_options: [
        ip: {0, 0, 0, 0},
        reuseaddr: true
      ],
      read_timeout: 60_000,
      shutdown_timeout: 15_000,
      num_listeners: 10,
      num_connections: 1000,
      max_packet_size: 1024
    }
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    server_config = build_server_config(opts)
    port = Keyword.get(server_config, :port, 67)

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :server, :starting],
      %{count: 1},
      %{port: port}
    )

    case Abyss.start_link(server_config) do
      {:ok, abyss_pid} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :server, :started],
          %{count: 1},
          %{port: port}
        )

        {:ok, %{abyss_pid: abyss_pid, config: server_config}}

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :server, :start_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:stop, reason}
    end
  end

  @impl true
  def terminate(reason, state) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :server, :stopping],
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

          updated_keywords =
            Keyword.put(config_keywords, :transport_options, updated_transport_opts)

          {updated_keywords, Keyword.delete(opts, :listen)}
      end

    # Filter out DHCP-specific options that Abyss doesn't understand
    abyss_opts = Keyword.drop(opts_with_transport, @dhcp_specific_keys)

    # Override with provided options (from main YellowDog app)
    config_keywords
    |> Keyword.merge(abyss_opts)
    |> Keyword.put(:handler_module, YellowDog.Dhcpv4.Handler)
    |> Keyword.put(:transport_module, Abyss.Transport.UDP.Broadcast)
  end
end
