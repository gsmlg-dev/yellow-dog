defmodule E2ETest.ServiceHelper do
  @moduledoc """
  Helper module for starting and stopping YellowDog services in E2E tests.

  Provides functions to start services with auto-selected ports (port 0),
  retrieve the assigned port, and cleanly stop services after tests.
  """

  @default_timeout 10_000

  @doc """
  Starts the DNS server with auto-selected port.

  Returns a context map with server pid, assigned port, and host.

  ## Options
  - `:listen` - IP address to bind to (default: {127, 0, 0, 1})
  - `:timeout` - Startup timeout in ms (default: 10_000)

  ## Returns
  - `{:ok, %{server_pid: pid, port: port, host: ip, service: :dns}}`
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

    start_service(YellowDog.Dns.Server, server_opts, :dns, host, timeout)
  end

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
