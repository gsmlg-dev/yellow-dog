defmodule E2ETest.ServiceHelper do
  @moduledoc """
  Helper module for starting and stopping YellowDog services in E2E tests.

  Provides functions to start services with auto-selected ports (port 0),
  retrieve the assigned port, and cleanly stop services after tests.
  """

  @default_timeout 10_000

  @doc """
  Starts the DNS server with auto-selected port.

  Returns a context map with server pid, assigned UDP port, TCP port, and host.

  ## Options
  - `:listen` - IP address to bind to (default: {127, 0, 0, 1})
  - `:timeout` - Startup timeout in ms (default: 10_000)

  ## Returns
  - `{:ok, %{server_pid: pid, port: udp_port, tcp_port: tcp_port, host: ip, service: :dns}}`
  - `{:error, reason}`
  """
  @spec start_dns_server(keyword()) :: {:ok, map()} | {:error, term()}
  def start_dns_server(opts \\ []) do
    host = Keyword.get(opts, :listen, {127, 0, 0, 1})
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    server_opts = [
      port: 0,
      listen: host,
      transport_options: [ip: host, reuseaddr: true]
    ]

    start_dns_service(YellowDog.Dns.Server, server_opts, host, timeout)
  end

  # Special start function for DNS that retrieves both UDP and TCP ports
  defp start_dns_service(module, opts, host, timeout) do
    # Unregister any existing named process
    try do
      if Process.whereis(module) do
        GenServer.stop(module, :normal, 1_000)
      end
    catch
      _, _ -> :ok
    end

    # Wait a bit for cleanup
    Process.sleep(100)

    case apply(module, :start_link, [opts]) do
      {:ok, pid} ->
        # Wait for service to be ready
        Process.sleep(200)

        if Process.alive?(pid) do
          # Get UDP port
          udp_port_result = get_dns_udp_port(pid)
          # Get TCP port
          tcp_port_result = get_dns_tcp_port(pid)

          case {udp_port_result, tcp_port_result} do
            {{:ok, udp_port}, {:ok, tcp_port}} ->
              {:ok,
               %{
                 server_pid: pid,
                 port: udp_port,
                 tcp_port: tcp_port,
                 host: host,
                 service: :dns
               }}

            {{:ok, udp_port}, {:error, _}} ->
              # TCP port detection failed but UDP works - still usable
              {:ok,
               %{
                 server_pid: pid,
                 port: udp_port,
                 tcp_port: nil,
                 host: host,
                 service: :dns
               }}

            {{:error, reason}, _} ->
              # Cleanup on failure
              try do
                GenServer.stop(pid, :normal, 1_000)
              catch
                _, _ -> :ok
              end

              {:error, {:udp_port_detection_failed, reason}}
          end
        else
          {:error, :process_died}
        end

      {:error, reason} ->
        {:error, {:start_failed, reason}}
    end
  end

  defp get_dns_udp_port(pid) do
    try do
      YellowDog.Dns.Server.get_udp_port(pid)
    catch
      _, _ -> {:error, :udp_port_unavailable}
    end
  end

  defp get_dns_tcp_port(pid) do
    try do
      YellowDog.Dns.Server.get_tcp_port(pid)
    catch
      _, _ -> {:error, :tcp_port_unavailable}
    end
  end

  @doc """
  Starts the full DNS subsystem (Supervisor + Server + ViewManager + ZoneController).

  Unlike `start_dns_server/1` which only starts the bare Server, this starts
  the complete DNS process hierarchy including views, zones, registries, etc.

  ## Options
  - `:listen` - IP address to bind to (default: {127, 0, 0, 1})
  - `:views` - Initial view configurations (default: [])
  - `:zones` - Initial zone configurations (default: [])
  - `:timeout` - Startup timeout in ms (default: 15_000)

  ## Returns
  - `{:ok, %{server_pid: pid, port: udp_port, tcp_port: tcp_port, host: ip, service: :dns_system}}`
  - `{:error, reason}`
  """
  @spec start_dns_system(keyword()) :: {:ok, map()} | {:error, term()}
  def start_dns_system(opts \\ []) do
    host = Keyword.get(opts, :listen, {127, 0, 0, 1})
    views = Keyword.get(opts, :views, [])
    zones = Keyword.get(opts, :zones, [])

    # Stop existing DNS supervisor if running
    if pid = Process.whereis(YellowDog.Dns) do
      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        _, _ -> :ok
      end

      Process.sleep(200)
    end

    # Also stop any standalone registries left over from previous tests
    for name <- [
          YellowDog.Dns.ZoneRegistry,
          YellowDog.Dns.ViewRegistry,
          YellowDog.Dns.ConnectionRegistry,
          YellowDog.Dns.RecursionRegistry
        ] do
      if pid = Process.whereis(name) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          _, _ -> :ok
        end
      end
    end

    Process.sleep(100)

    sup_opts = [
      port: 0,
      listen: host,
      views: views,
      zones: zones,
      skip_persistence: true,
      transport_options: [ip: host, reuseaddr: true]
    ]

    case YellowDog.Dns.Supervisor.start_link(sup_opts) do
      {:ok, sup_pid} ->
        # Wait for post-init to complete
        Process.sleep(500)

        # Get the Server pid and ports from the supervisor tree
        server_pid = Process.whereis(YellowDog.Dns.Server)

        if server_pid && Process.alive?(server_pid) do
          udp_port_result = get_dns_udp_port(server_pid)
          tcp_port_result = get_dns_tcp_port(server_pid)

          udp_port =
            case udp_port_result do
              {:ok, p} -> p
              _ -> nil
            end

          tcp_port =
            case tcp_port_result do
              {:ok, p} -> p
              _ -> nil
            end

          if udp_port do
            {:ok,
             %{
               server_pid: sup_pid,
               port: udp_port,
               tcp_port: tcp_port,
               host: host,
               service: :dns_system
             }}
          else
            Supervisor.stop(sup_pid, :normal, 5_000)
            {:error, :udp_port_detection_failed}
          end
        else
          Supervisor.stop(sup_pid, :normal, 5_000)
          {:error, :server_not_started}
        end

      {:error, reason} ->
        {:error, {:start_failed, reason}}
    end
  end

  @doc """
  Stops the full DNS subsystem.
  """
  def stop_dns_system(%{server_pid: pid, service: :dns_system}) do
    if Process.alive?(pid) do
      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  def stop_dns_system(ctx), do: stop_service(ctx)

  @doc """
  Starts the mDNS server with auto-selected port using unicast mode.

  For E2E tests in CI, mDNS uses unicast to loopback instead of multicast.

  ## Options
  - `:listen` - IP address to bind to (default: {127, 0, 0, 1})
  - `:timeout` - Startup timeout in ms (default: 10_000)

  ## Returns
  - `{:ok, %{server_pid: pid, port: port, host: ip, service: :mdns}}`
  - `{:error, reason}`
  """
  @spec start_mdns_server(keyword()) :: {:ok, map()} | {:error, term()}
  def start_mdns_server(opts \\ []) do
    host = Keyword.get(opts, :listen, {127, 0, 0, 1})
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Use unicast mode for CI - skip multicast membership
    server_opts = [
      port: 0,
      listen_address: host,
      mode: :responder,
      transport_options: [ip: host, reuseaddr: true]
    ]

    start_service(YellowDog.Mdns.Server, server_opts, :mdns, host, timeout)
  end

  @doc """
  Starts the DHCPv4 server with auto-selected port.

  ## Options
  - `:listen` - IP address to bind to (default: {127, 0, 0, 1})
  - `:timeout` - Startup timeout in ms (default: 10_000)

  ## Returns
  - `{:ok, %{server_pid: pid, port: port, host: ip, service: :dhcpv4}}`
  - `{:error, reason}`
  """
  @spec start_dhcpv4_server(keyword()) :: {:ok, map()} | {:error, term()}
  def start_dhcpv4_server(opts \\ []) do
    host = Keyword.get(opts, :listen, {127, 0, 0, 1})
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    server_opts = [
      port: 0,
      listen: host,
      transport_options: [ip: host, reuseaddr: true]
    ]

    start_service(YellowDog.Dhcpv4.Server, server_opts, :dhcpv4, host, timeout)
  end

  @doc """
  Starts the DHCPv6 server with auto-selected port.

  ## Options
  - `:listen` - IP address to bind to (default: {0, 0, 0, 0, 0, 0, 0, 1} for IPv6 loopback)
  - `:timeout` - Startup timeout in ms (default: 10_000)

  ## Returns
  - `{:ok, %{server_pid: pid, port: port, host: ip, service: :dhcpv6}}`
  - `{:error, reason}`
  """
  @spec start_dhcpv6_server(keyword()) :: {:ok, map()} | {:error, term()}
  def start_dhcpv6_server(opts \\ []) do
    # IPv6 loopback
    host = Keyword.get(opts, :listen, {0, 0, 0, 0, 0, 0, 0, 1})
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    server_opts = [
      port: 0,
      listen: host,
      transport_options: [ip: host, ipv6_v6only: true, reuseaddr: true]
    ]

    start_service(YellowDog.Dhcpv6.Server, server_opts, :dhcpv6, host, timeout)
  end

  @doc """
  Stops a service using the context returned from start_*_server functions.

  ## Parameters
  - `ctx` - Context map from start_*_server containing :server_pid

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec stop_service(map()) :: :ok | {:error, term()}
  def stop_service(%{server_pid: pid} = _ctx) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
        :ok
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  def stop_service(_), do: :ok

  @doc """
  Waits for a service to be ready by checking if the process is alive.

  ## Parameters
  - `ctx` - Context map containing :server_pid
  - `timeout` - Maximum wait time in ms

  ## Returns
  - `:ok` when service is ready
  - `{:error, :timeout}` if service doesn't become ready in time
  """
  @spec wait_for_ready(map(), timeout()) :: :ok | {:error, :timeout}
  def wait_for_ready(%{server_pid: pid}, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_ready(pid, deadline)
  end

  defp do_wait_for_ready(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      if Process.alive?(pid) do
        :ok
      else
        Process.sleep(50)
        do_wait_for_ready(pid, deadline)
      end
    end
  end

  # Private helpers

  defp start_service(module, opts, service_type, host, timeout) do
    # Unregister any existing named process
    try do
      if Process.whereis(module) do
        GenServer.stop(module, :normal, 1_000)
      end
    catch
      _, _ -> :ok
    end

    # Wait a bit for cleanup
    Process.sleep(100)

    case apply(module, :start_link, [opts]) do
      {:ok, pid} ->
        # Wait for service to be ready
        case wait_for_port(pid, timeout) do
          {:ok, port} ->
            {:ok,
             %{
               server_pid: pid,
               port: port,
               host: host,
               service: service_type
             }}

          {:error, reason} ->
            # Cleanup on failure
            try do
              GenServer.stop(pid, :normal, 1_000)
            catch
              _, _ -> :ok
            end

            {:error, {:port_detection_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:start_failed, reason}}
    end
  end

  # Wait for the service to bind to a port and return the assigned port
  # Since servers use Abyss internally which binds synchronously in init,
  # the port should be available immediately after start_link returns.
  # We use a small delay to ensure socket is fully bound.
  defp wait_for_port(pid, _timeout) do
    Process.sleep(200)

    if Process.alive?(pid) do
      # Try the get_port function if available (new supervisor-based servers)
      try do
        case get_port_via_api(pid) do
          {:ok, port} -> {:ok, port}
          {:error, _} -> get_port_via_state(pid)
        end
      catch
        _, _ -> get_port_via_state(pid)
      end
    else
      {:error, :process_died}
    end
  end

  # Try to get port via the server's get_port API (for supervisor-based servers)
  # Only use for DNS servers which are now Supervisors - other servers are GenServers
  defp get_port_via_api(_pid) do
    # Skip API-based port detection - use state-based detection instead
    # This avoids calling Supervisor.which_children on GenServer-based servers
    # like mDNS, DHCPv4, and DHCPv6 which would crash them
    {:error, :no_get_port_api}
  end

  # Get port via sys:get_state for GenServer-based servers, or via
  # Supervisor.which_children for Supervisor-based servers (like DNS)
  defp get_port_via_state(pid) do
    # Get state first - this works for both GenServers and Supervisors
    try do
      state = :sys.get_state(pid, 5_000)

      # Check if this is a Supervisor state (tuple format) or GenServer state (map)
      case state do
        # Supervisor internal state is a complex tuple, but we can detect it
        # by checking if the process responds to which_children
        # For now, check if it's a map with abyss_pid (GenServer pattern)
        %{abyss_pid: abyss_pid} when is_pid(abyss_pid) ->
          get_port_from_abyss(abyss_pid)

        %{config: config} when is_list(config) ->
          case Keyword.get(config, :port) do
            nil -> {:error, :port_not_in_config}
            0 -> {:error, :port_is_zero}
            port -> {:ok, port}
          end

        # Supervisor state - need to call which_children to find Abyss
        # This is a Supervisor internal state tuple
        {_, _, _, children, _, _, _, _, _, _} when is_map(children) ->
          get_port_from_supervisor_pid(pid)

        # Also check for simpler supervisor state format
        _ when is_tuple(state) ->
          get_port_from_supervisor_pid(pid)

        _ ->
          {:error, :unknown_state_format}
      end
    catch
      _, _ -> {:error, :state_unavailable}
    end
  end

  # Get port from Supervisor by calling which_children
  defp get_port_from_supervisor_pid(pid) do
    try do
      children = Supervisor.which_children(pid)
      get_port_from_supervisor_children(children)
    catch
      _, _ -> {:error, :supervisor_children_failed}
    end
  end

  # Get port from Supervisor children list (for Supervisor-based servers like DNS)
  defp get_port_from_supervisor_children(children) do
    # Find Abyss child in the children list
    abyss_pid =
      Enum.find_value(children, fn
        {:abyss, child_pid, :supervisor, _} when is_pid(child_pid) -> child_pid
        _ -> nil
      end)

    case abyss_pid do
      nil -> {:error, :abyss_not_found}
      pid -> get_port_from_abyss(pid)
    end
  end


  defp get_port_from_abyss(abyss_pid) do
    # Try to get listener pool and then listener info
    try do
      case Abyss.Server.listener_pool_pid(abyss_pid) do
        nil ->
          {:error, :no_listener_pool}

        pool_pid ->
          case Abyss.ListenerPool.listener_pids(pool_pid) do
            [] ->
              {:error, :no_listeners}

            [listener_pid | _] ->
              info = Abyss.Listener.listener_info(listener_pid)

              case info do
                {_ip, port} when is_integer(port) -> {:ok, port}
                _ -> {:error, :invalid_listener_info}
              end
          end
      end
    catch
      _, _ -> {:error, :abyss_info_failed}
    end
  end
end
