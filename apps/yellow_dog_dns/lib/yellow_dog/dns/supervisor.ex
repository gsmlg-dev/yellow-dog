defmodule YellowDog.Dns.Supervisor do
  @moduledoc """
  Top-level supervisor for the DNS subsystem.

  Started by `YellowDog.Dns.Application`, this supervisor manages:
  - `YellowDog.Dns.Server` - Network I/O servers (Abyss UDP + ThousandIsland TCP)
  - `YellowDog.Dns.ZoneController` - Supervises zone processes
  - `YellowDog.Dns.ViewManager` - Manages DNS views and routing
  - `YellowDog.Dns.ConnectionManager` - Manages connection processes for DNS resolution

  ## Process Hierarchy

      YellowDog.Dns.Supervisor
      ├── YellowDog.Dns.Server (Supervisor)
      │   ├── Abyss (UDP Server)
      │   └── ThousandIsland (TCP Server)
      ├── ConnectionManager (DynamicSupervisor)
      │   └── Connection Processes (per-connection)
      ├── ViewManager (Supervisor)
      │   └── View processes (GenServer, one per configured view)
      └── ZoneController (Supervisor)
          └── Zone processes (Auth, Forward, Stub, Root, Cache, RPZ)
  """

  use Supervisor

  alias YellowDog.Telemetry

  @doc """
  Starts the DNS supervisor.

  ## Options
  - `port`: UDP port to listen on (default: 53)
  - `listen`: IP address to bind to (default: "0.0.0.0")
  - `views`: Initial view configurations
  - `zones`: Initial zone configurations

  ## Returns
  - `{:ok, pid}` - Supervisor started successfully
  - `{:error, reason}` - Failed to start supervisor
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    # Register as YellowDog.Dns (not YellowDog.Dns.Supervisor) to match other services
    Supervisor.start_link(__MODULE__, opts, name: YellowDog.Dns)
  end

  @doc """
  Stops the DNS supervisor.
  """
  @spec stop(pid() | atom()) :: :ok
  def stop(pid \\ YellowDog.Dns) do
    Supervisor.stop(pid)
  end

  @doc """
  Returns the status of the DNS subsystem.
  """
  @spec status() :: map()
  def status do
    %{
      running: Process.whereis(YellowDog.Dns) != nil,
      server: safe_call(fn -> YellowDog.Dns.Server.status() end, %{running: false}),
      connection_stats: safe_call(fn -> YellowDog.Dns.ConnectionManager.stats() end, %{}),
      view_stats: safe_call(fn -> YellowDog.Dns.ViewManager.stats() end, %{}),
      zone_count: safe_call(fn -> length(YellowDog.Dns.ZoneController.list_zones()) end, 0)
    }
  end

  # Supervisor callbacks

  @impl true
  def init(opts) do
    Telemetry.info("Starting DNS supervisor")

    # Get server configuration
    port = get_port(opts)
    listen = get_listen(opts)

    # Attach Abyss logger if debug is enabled
    if get_debug(opts) do
      Telemetry.info("Attaching Abyss debug logger")
      Abyss.Logger.attach_logger(:debug)
    end

    Telemetry.info("DNS supervisor configuration", %{
      port: port,
      listen: format_ip(listen)
    })

    children = [
      # Registries for named processes
      {Registry, keys: :unique, name: YellowDog.Dns.ZoneRegistry},
      {Registry, keys: :unique, name: YellowDog.Dns.ViewRegistry},
      {Registry, keys: :unique, name: YellowDog.Dns.ConnectionRegistry},

      # ZoneController - supervises zone processes
      {YellowDog.Dns.ZoneController, name: YellowDog.Dns.ZoneController},

      # ViewManager - supervises view processes and routes requests
      {YellowDog.Dns.ViewManager, name: YellowDog.Dns.ViewManager},

      # ConnectionManager - manages per-connection processes
      {YellowDog.Dns.ConnectionManager, name: YellowDog.Dns.ConnectionManager},

      # Server - network I/O (Abyss UDP + ThousandIsland TCP)
      {YellowDog.Dns.Server, Keyword.merge(opts, port: port, listen: listen)},

      # Post-init task - set up default view and zones
      # Uses restart: :temporary so it doesn't restart after completion
      %{
        id: :post_init,
        start: {Task, :start_link, [fn -> post_init(opts) end]},
        restart: :temporary
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private helpers

  defp post_init(opts) do
    # Wait for required processes to be ready
    wait_for_process(YellowDog.Dns.ViewManager)
    wait_for_process(YellowDog.Dns.ZoneController)

    # Start default view if no views configured
    views = Keyword.get(opts, :views, [])

    if Enum.empty?(views) do
      YellowDog.Dns.ViewManager.start_view(%{
        name: "default",
        priority: :infinity,
        acl: :any,
        zones: [],
        rpz_zones: [],
        recursion_enabled: true,
        ecs_enabled: false
      })
    else
      Enum.each(views, &YellowDog.Dns.ViewManager.start_view/1)
    end

    # Start configured zones
    zones = Keyword.get(opts, :zones, [])
    Enum.each(zones, &start_zone/1)

    # Set up default forwarding zone if not configured
    upstreams = get_upstreams()

    if upstreams != [] do
      YellowDog.Dns.ZoneController.start_zone(:forward, ".", upstreams: upstreams)
    end

    Telemetry.info("DNS supervisor post-init completed")
  end

  defp start_zone(zone_config) do
    type = Map.get(zone_config, :type, :auth)
    name = Map.get(zone_config, :name)
    opts = Map.to_list(zone_config)

    # Add zone_data_path for auth zones
    opts =
      if type == :auth do
        case get_zone_data_path() do
          nil -> opts
          path -> Keyword.put(opts, :zone_data_path, path)
        end
      else
        opts
      end

    YellowDog.Dns.ZoneController.start_zone(type, name, opts)
  end

  defp get_zone_data_path do
    apply(YellowDog.Config, :get, [:dns, :zone_data_path])
  rescue
    _ -> nil
  end

  defp get_port(opts) do
    Keyword.get(opts, :port) ||
      apply(YellowDog.Config, :get, [:dns, :port]) ||
      53
  rescue
    _ -> 53
  end

  defp get_listen(opts) do
    listen =
      Keyword.get(opts, :listen) ||
        apply(YellowDog.Config, :get, [:dns, :listen]) ||
        "0.0.0.0"

    case parse_ip(listen) do
      {:ok, ip} -> ip
      {:error, _} -> {0, 0, 0, 0}
    end
  rescue
    _ -> {0, 0, 0, 0}
  end

  defp get_debug(opts) do
    case Keyword.get(opts, :debug) do
      nil ->
        case apply(YellowDog.Config, :get, [:dns, :debug]) do
          true -> true
          "true" -> true
          _ -> false
        end

      value when is_boolean(value) ->
        value

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp get_upstreams do
    case apply(YellowDog.Config, :get, [:dns, :upstream_servers]) do
      nil -> [{{8, 8, 8, 8}, 53}, {{1, 1, 1, 1}, 53}]
      servers when is_list(servers) -> parse_upstreams(servers)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp parse_upstreams(servers) do
    Enum.map(servers, fn
      {ip, port} when is_tuple(ip) -> {ip, port}
      ip when is_tuple(ip) -> {ip, 53}
      ip_str when is_binary(ip_str) -> parse_upstream_string(ip_str)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_upstream_string(str) do
    case String.split(str, ":") do
      [ip_str, port_str] ->
        with {:ok, ip} <- parse_ip(ip_str),
             {port, ""} <- Integer.parse(port_str) do
          {ip, port}
        else
          _ -> nil
        end

      [ip_str] ->
        case parse_ip(ip_str) do
          {:ok, ip} -> {ip, 53}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_ip(ip_str) when is_binary(ip_str) do
    charlist = String.to_charlist(ip_str)

    case :inet.parse_ipv4_address(charlist) do
      {:ok, ip} ->
        {:ok, ip}

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

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  # Waits for a named process to be registered, with timeout
  defp wait_for_process(name, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_process(name, deadline)
  end

  defp do_wait_for_process(name, deadline) do
    case Process.whereis(name) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_wait_for_process(name, deadline)
        else
          Telemetry.warning("Timeout waiting for process", %{name: name})
          :timeout
        end

      pid when is_pid(pid) ->
        :ok
    end
  end
end
