defmodule YellowDog.Dns do
  @moduledoc """
  DNS application that manages DNS functionality including name resolution, zones, and views.

  The DNS application provides a complete DNS server implementation with support for:
  - Standard DNS query types (A, AAAA, MX, NS, SOA, TXT, CNAME, etc.)
  - DNS views for split-horizon DNS
  - Zone management with authoritative, forward, cache, stub, and root zones
  - Per-view caching for improved performance
  - Response Policy Zones (RPZ) for DNS firewall
  - Integration with the YellowDog configuration system

  ## Architecture

  The DNS application uses a process hierarchy for separation of concerns:

  ```
  YellowDog.Dns.Supervisor
  ├── YellowDog.Dns.Server (Supervisor)
  │   ├── Abyss (UDP Server)
  │   └── ThousandIsland (TCP Server)
  ├── ConnectionManager (DynamicSupervisor)
  │   └── Connection Processes (per-connection)
  │       └── Tracks multiple in-flight queries concurrently
  ├── ViewManager (Supervisor)
  │   └── View processes (GenServer, one per configured view)
  │       ├── RecursionController (if recursive enabled)
  │       ├── Zone references
  │       └── RPZ references
  └── ZoneController (Supervisor)
      └── Zone processes (Auth, Forward, Stub, Root, Cache, RPZ)
  ```

  ## Process Responsibilities

  - **YellowDog.Dns.Supervisor**: Top-level supervisor for DNS service
  - **YellowDog.Dns.Server**: Network I/O only (Abyss UDP + ThousandIsland TCP)
  - **YellowDog.Dns.Handler**: Network I/O bridge, delegates to ConnectionManager
  - **YellowDog.Dns.ConnectionManager**: Supervises connection processes
  - **YellowDog.Dns.ConnectionProcess**: Per-connection query orchestration with telemetry
  - **YellowDog.Dns.ViewManager**: Routes requests to appropriate View by ACL matching
  - **YellowDog.Dns.View**: Per-view GenServer with zone/RPZ routing
  - **YellowDog.Dns.ZoneController**: Manages zone process lifecycle

  ## Usage

  The DNS application is typically started as part of the YellowDog umbrella
  application and can be configured through the centralized configuration system.

  ```elixir
  # Start the DNS server
  {:ok, _pid} = YellowDog.Dns.start_link([])

  # Or use it as a child in a supervisor
  children = [
    {YellowDog.Dns, port: 53, listen: "0.0.0.0"}
  ]
  ```

  ## Configuration

  The DNS server can be configured through the YellowDog configuration system:

  ```elixir
  # In your configuration
  config :dns,
    port: 53,
    listen: "0.0.0.0"
  ```
  """

  @doc """
  Starts the DNS server.

  Delegates to `YellowDog.Dns.Supervisor.start_link/1`.

  ## Options
  - `port`: UDP port to listen on (default: 53)
  - `listen`: IP address to bind to (default: "0.0.0.0")
  - `views`: Initial view configurations
  - `zones`: Initial zone configurations

  ## Returns
  - `{:ok, pid}` - Server started successfully
  - `{:error, reason}` - Failed to start server
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options \\ []), to: YellowDog.Dns.Supervisor

  @doc """
  Returns a child specification for the DNS server.

  ## Returns
  - `Supervisor.child_spec()` - Child specification for the DNS server
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {YellowDog.Dns.Supervisor, :start_link, [options]},
      type: :supervisor
    }
  end

  @doc """
  Gets the status of the DNS service.

  ## Returns
  - Map with service status information

  ## Examples
      iex> YellowDog.Dns.status()
      %{
        running: true,
        info: "DNS service operational"
      }
  """
  @spec status() :: map()
  def status do
    case Process.whereis(YellowDog.Dns.Supervisor) do
      nil ->
        %{running: false, info: "DNS service not running"}

      _pid ->
        %{
          running: true,
          info: "DNS service operational"
        }
    end
  end

  @doc """
  Gets DNS statistics.

  Returns comprehensive statistics about the DNS service including zone information,
  view statistics, connection statistics, and service status.

  ## Returns
  - Map with DNS statistics including:
    - `zones` - Zone count and statistics from ZoneController
    - `views` - View statistics from ViewManager
    - `connections` - Active connection statistics from ConnectionManager
    - `service` - Service status information

  ## Examples
      iex> YellowDog.Dns.stats()
      %{
        zones: %{count: 3},
        views: %{count: 1},
        connections: %{active: 0},
        service: %{running: true, info: "DNS service operational"}
      }
  """
  @spec stats() :: map()
  def stats do
    # Get zone statistics
    zone_stats =
      try do
        zones = YellowDog.Dns.ZoneController.list_zones()
        %{count: length(zones)}
      catch
        :exit, _ -> %{error: "ZoneController not running"}
      end

    # Get view statistics
    view_stats =
      try do
        YellowDog.Dns.ViewManager.stats()
      catch
        :exit, _ -> %{error: "ViewManager not running"}
      end

    # Get connection statistics
    connection_stats =
      try do
        YellowDog.Dns.ConnectionManager.stats()
      catch
        :exit, _ -> %{error: "ConnectionManager not running"}
      end

    # Get service status
    service_status = status()

    %{
      zones: zone_stats,
      views: view_stats,
      connections: connection_stats,
      service: service_status
    }
  end

  @doc """
  Returns the port the DNS server is listening on.

  Useful for tests when starting with port 0 (auto-select).
  """
  @spec get_port() :: {:ok, :inet.port_number()} | {:error, term()}
  def get_port do
    YellowDog.Dns.Server.get_port()
  end
end
