defmodule YellowDog.Dns do
  @moduledoc """
  DNS application that manages DNS functionality including name resolution, zones, and views.

  The DNS application provides a complete DNS server implementation with support for:
  - Standard DNS query types (A, AAAA, MX, NS, SOA, TXT, CNAME, etc.)
  - DNS views for split-horizon DNS
  - Zone management with authoritative, forward, cache, stub, and root zones
  - Per-view caching for improved performance
  - Integration with the YellowDog configuration system

  ## Architecture

  The DNS application uses a process hierarchy for separation of concerns:

  - **YellowDog.Dns.Server**: Supervisor managing all DNS subsystem components
  - **YellowDog.Dns.Handler.UDP**: Network I/O only, delegates to ViewManager
  - **YellowDog.Dns.ViewManager**: Routes requests to appropriate View processes
  - **YellowDog.Dns.ViewProcess**: Per-view GenServer with ACL matching and zone routing
  - **YellowDog.Dns.ZoneController**: Manages zone processes (Auth, Forward, Cache, Stub, Root)
  - **YellowDog.Dns.SpanManager**: Tracks active requests via TSI (Telemetry Span Items)

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

  Delegates to `YellowDog.Dns.Server.start_link/1`.

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
  defdelegate start_link(options \\ []), to: YellowDog.Dns.Server

  @doc """
  Returns a child specification for the DNS server.

  ## Returns
  - `Supervisor.child_spec()` - Child specification for the DNS server
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: YellowDog.Dns.Server

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
    case Process.whereis(YellowDog.Dns.Server) do
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
  view statistics, and service status.

  ## Returns
  - Map with DNS statistics including:
    - `zones` - Zone count and statistics from ZoneController
    - `views` - View statistics from ViewManager
    - `spans` - Active request statistics from SpanManager
    - `service` - Service status information

  ## Examples
      iex> YellowDog.Dns.stats()
      %{
        zones: %{count: 3},
        views: %{count: 1},
        spans: %{active: 0},
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

    # Get span statistics
    span_stats =
      try do
        YellowDog.Dns.SpanManager.stats()
      catch
        :exit, _ -> %{error: "SpanManager not running"}
      end

    # Get service status
    service_status = status()

    %{
      zones: zone_stats,
      views: view_stats,
      spans: span_stats,
      service: service_status
    }
  end
end
