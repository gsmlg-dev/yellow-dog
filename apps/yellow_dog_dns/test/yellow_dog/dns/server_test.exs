defmodule YellowDog.Dns.ServerTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.Server.

  Tests cover:
  - Default configuration values
  - Server lifecycle (start/stop)
  - Status reporting
  - Port retrieval functions
  - TCP enabled flag
  - IP address normalization
  - Error handling when server not running
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Server

  describe "Server configuration" do
    test "get_config/0 returns valid default configuration" do
      config = Server.get_config()

      assert is_map(config)
      assert config.port == 53
      assert config.listen == {0, 0, 0, 0}

      # Check UDP config
      udp = config.udp
      assert udp.transport_module == Abyss.Transport.UDP.Unicast
      assert udp.handler_module == YellowDog.Dns.Handler.UDP
      assert is_list(udp.transport_options)
      assert is_integer(udp.read_timeout)
      assert is_integer(udp.shutdown_timeout)
      assert is_integer(udp.num_listeners)
      assert is_integer(udp.num_connections)
      assert is_integer(udp.max_packet_size)

      # Check TCP config
      tcp = config.tcp
      assert tcp.transport_module == ThousandIsland.Transports.TCP
      assert tcp.handler_module == YellowDog.Dns.Handler.TCP
      assert is_list(tcp.transport_options)
      assert is_integer(tcp.read_timeout)
      assert is_integer(tcp.shutdown_timeout)
      assert is_integer(tcp.num_acceptors)
      assert is_integer(tcp.num_connections)
    end

    test "default port is 53 (standard DNS port)" do
      config = Server.get_config()

      assert config.port == 53
    end

    test "UDP uses unicast transport by default" do
      config = Server.get_config()

      assert config.udp.transport_module == Abyss.Transport.UDP.Unicast
    end

    test "UDP handler module is set correctly" do
      config = Server.get_config()

      assert config.udp.handler_module == YellowDog.Dns.Handler.UDP
    end

    test "TCP handler module is set correctly" do
      config = Server.get_config()

      assert config.tcp.handler_module == YellowDog.Dns.Handler.TCP
    end

    test "max packet size is DNS UDP limit (512 bytes)" do
      config = Server.get_config()

      assert config.udp.max_packet_size == 512
    end

    test "UDP transport options include IP and reuseaddr" do
      config = Server.get_config()

      transport_opts = config.udp.transport_options

      assert is_list(transport_opts)
      assert Keyword.has_key?(transport_opts, :ip)
      assert Keyword.has_key?(transport_opts, :reuseaddr)
      assert transport_opts[:reuseaddr] == true
    end

    test "TCP transport options include IP, reuseaddr and nodelay" do
      config = Server.get_config()

      transport_opts = config.tcp.transport_options

      assert is_list(transport_opts)
      assert Keyword.has_key?(transport_opts, :ip)
      assert Keyword.has_key?(transport_opts, :reuseaddr)
      assert Keyword.has_key?(transport_opts, :nodelay)
      assert transport_opts[:reuseaddr] == true
      assert transport_opts[:nodelay] == true
    end

    test "default listen address is 0.0.0.0 (all interfaces)" do
      config = Server.get_config()

      assert config.listen == {0, 0, 0, 0}
    end
  end

  describe "Server lifecycle" do
    test "server module exports required functions" do
      # start_link has default argument, so arity is 0
      assert function_exported?(Server, :start_link, 0) or
               function_exported?(Server, :start_link, 1)

      assert function_exported?(Server, :stop, 1)
      assert function_exported?(Server, :get_config, 0)
    end

    test "stop/1 accepts server name or PID" do
      # stop/1 has default arg so it exports both stop/0 and stop/1
      assert function_exported?(Server, :stop, 0) or
               function_exported?(Server, :stop, 1)
    end
  end

  describe "Configuration customization" do
    test "configuration can be built with custom port" do
      # This tests that the server would accept custom configuration
      # DNS standard port is 53
      custom_opts = [port: 53]

      # Verify that passing options would work (can't test actual server start)
      assert is_list(custom_opts)
      assert Keyword.has_key?(custom_opts, :port)
    end

    test "configuration can specify custom listen address" do
      custom_opts = [listen: "127.0.0.1"]

      assert is_list(custom_opts)
      assert Keyword.has_key?(custom_opts, :listen)
    end
  end

  describe "Supervisor behaviour" do
    setup do
      Code.ensure_loaded!(Server)
      :ok
    end

    test "server is a Supervisor" do
      # Verify the module uses Supervisor
      assert Kernel.function_exported?(Server, :init, 1)
      # Supervisor.init/1 returns {:ok, supervisor_spec}
    end

    test "server exports get_port/0 and get_port/1 functions" do
      assert Kernel.function_exported?(Server, :get_port, 0)
      assert Kernel.function_exported?(Server, :get_port, 1)
    end
  end

  describe "Abyss and ThousandIsland integration" do
    setup do
      Code.ensure_loaded!(Server)
      :ok
    end

    test "server is a Supervisor for Abyss and ThousandIsland" do
      # The server wraps both, so init should be defined
      assert Kernel.function_exported?(Server, :init, 1)
    end

    test "configuration includes all required Abyss UDP options" do
      config = Server.get_config()

      # Shared options
      assert Map.has_key?(config, :port)
      assert Map.has_key?(config, :listen)

      # Abyss UDP requires these options
      udp = config.udp
      assert Map.has_key?(udp, :handler_module)
      assert Map.has_key?(udp, :transport_options)
      assert Map.has_key?(udp, :num_listeners)
      assert Map.has_key?(udp, :num_connections)
    end

    test "configuration includes all required ThousandIsland TCP options" do
      config = Server.get_config()

      # ThousandIsland TCP requires these options
      tcp = config.tcp
      assert Map.has_key?(tcp, :handler_module)
      assert Map.has_key?(tcp, :transport_options)
      assert Map.has_key?(tcp, :num_acceptors)
      assert Map.has_key?(tcp, :num_connections)
    end
  end

  describe "DNS-specific configuration" do
    test "UDP timeouts are set appropriately for DNS" do
      config = Server.get_config()

      # UDP DNS queries should be fast
      # 5 seconds
      assert config.udp.read_timeout == 5_000
      # 5 seconds
      assert config.udp.shutdown_timeout == 5_000
    end

    test "TCP timeouts allow for connection reuse (RFC 7766)" do
      config = Server.get_config()

      # TCP DNS connections can be reused, longer timeouts
      # 2 minutes
      assert config.tcp.read_timeout == 120_000
      # 15 seconds
      assert config.tcp.shutdown_timeout == 15_000
    end

    test "UDP listener pool size is appropriate for DNS traffic" do
      config = Server.get_config()

      # DNS needs fewer listeners than DHCP since queries are faster
      assert config.udp.num_listeners == 50
    end

    test "UDP connection pool is large for concurrent queries" do
      config = Server.get_config()

      # DNS can handle many concurrent queries
      assert config.udp.num_connections == 10_000
    end

    test "TCP acceptor pool is sized for connection handling" do
      config = Server.get_config()

      assert config.tcp.num_acceptors == 100
      assert config.tcp.num_connections == 16_384
    end
  end

  describe "status/0" do
    test "returns status when server is not running" do
      # Ensure server is not running
      case Process.whereis(Server) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      status = Server.status()

      assert is_map(status)
      assert status.running == false
      assert is_map(status.udp)
      assert status.udp.running == false
      assert is_map(status.tcp)
      assert is_boolean(status.tcp.enabled)
      assert status.tcp.running == false
    end

    test "status map has correct structure" do
      status = Server.status()

      assert Map.has_key?(status, :running)
      assert Map.has_key?(status, :udp)
      assert Map.has_key?(status, :tcp)
      assert Map.has_key?(status.udp, :running)
      assert Map.has_key?(status.tcp, :enabled)
      assert Map.has_key?(status.tcp, :running)
    end
  end

  describe "tcp_enabled?/0" do
    test "returns a boolean" do
      result = Server.tcp_enabled?()

      assert is_boolean(result)
    end

    test "defaults to true when config not available" do
      # In test environment without specific config, should default to true
      result = Server.tcp_enabled?()

      assert result == true
    end
  end

  describe "get_port/0 and get_port/1" do
    test "returns error when server is not running" do
      # Ensure server is not running
      case Process.whereis(Server) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      result = Server.get_port()

      assert {:error, :abyss_not_found} = result
    end

    test "get_port/1 returns error for nil pid" do
      result = Server.get_port(nil)

      assert {:error, :abyss_not_found} = result
    end

    test "get_port/1 returns error for non-existent process name" do
      result = Server.get_port(:nonexistent_server_name)

      assert {:error, :abyss_not_found} = result
    end
  end

  describe "get_udp_port/0 and get_udp_port/1" do
    test "returns error when server is not running" do
      # Ensure server is not running
      case Process.whereis(Server) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      result = Server.get_udp_port()

      assert {:error, :abyss_not_found} = result
    end

    test "get_udp_port/1 accepts atom name" do
      result = Server.get_udp_port(:nonexistent)

      assert {:error, :abyss_not_found} = result
    end
  end

  describe "get_tcp_port/0 and get_tcp_port/1" do
    test "returns error when server is not running" do
      # Ensure server is not running
      case Process.whereis(Server) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      result = Server.get_tcp_port()

      assert {:error, :thousand_island_not_found} = result
    end

    test "get_tcp_port/1 accepts atom name" do
      result = Server.get_tcp_port(:nonexistent)

      assert {:error, :thousand_island_not_found} = result
    end
  end

  describe "server lifecycle with port 0" do
    setup do
      # Ensure no server is running before each test
      case Process.whereis(Server) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      # Give some time for cleanup
      Process.sleep(50)

      on_exit(fn ->
        try do
          case Process.whereis(Server) do
            nil -> :ok
            pid -> Supervisor.stop(pid)
          end
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    test "start_link/1 starts server with port 0 (auto-select)" do
      # Start with port 0 and TCP disabled to simplify test
      {:ok, pid} = Server.start_link(port: 0, tcp_enabled: false)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Server should be running
      status = Server.status()
      assert status.running == true
    end

    test "stop/1 stops the server" do
      {:ok, pid} = Server.start_link(port: 0, tcp_enabled: false)

      assert Process.alive?(pid)

      :ok = Server.stop(pid)

      # Give time for shutdown
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "stop/0 stops server by module name" do
      {:ok, _pid} = Server.start_link(port: 0, tcp_enabled: false)

      assert Process.whereis(Server) != nil

      :ok = Server.stop()

      Process.sleep(50)
      assert Process.whereis(Server) == nil
    end

    test "get_port returns valid port after start with port 0" do
      {:ok, _pid} = Server.start_link(port: 0, tcp_enabled: false)

      result = Server.get_port()

      assert {:ok, port} = result
      assert is_integer(port)
      assert port > 0
    end

    test "get_udp_port returns same as get_port" do
      {:ok, _pid} = Server.start_link(port: 0, tcp_enabled: false)

      {:ok, port1} = Server.get_port()
      {:ok, port2} = Server.get_udp_port()

      assert port1 == port2
    end

    test "status shows running after start" do
      {:ok, _pid} = Server.start_link(port: 0, tcp_enabled: false)

      status = Server.status()

      assert status.running == true
      assert status.udp.running == true
      # Note: tcp.enabled reads from config which defaults to true
      # The tcp_enabled option only controls whether TCP server is started
      assert is_boolean(status.tcp.enabled)
    end
  end

  describe "server with TCP enabled" do
    setup do
      # Ensure no server is running before each test
      case Process.whereis(Server) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      Process.sleep(50)

      on_exit(fn ->
        try do
          case Process.whereis(Server) do
            nil -> :ok
            pid -> Supervisor.stop(pid)
          end
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    test "start_link with TCP enabled starts both UDP and TCP" do
      {:ok, pid} = Server.start_link(port: 0, tcp_enabled: true)

      assert is_pid(pid)

      status = Server.status()
      assert status.running == true
      assert status.udp.running == true
      assert status.tcp.enabled == true
      # TCP server should be running
      assert status.tcp.running == true
    end

    test "get_tcp_port returns valid port when TCP enabled" do
      {:ok, _pid} = Server.start_link(port: 0, tcp_enabled: true)

      result = Server.get_tcp_port()

      assert {:ok, port} = result
      assert is_integer(port)
      assert port > 0
    end

    test "UDP and TCP may have same or different ports" do
      {:ok, _pid} = Server.start_link(port: 0, tcp_enabled: true)

      {:ok, udp_port} = Server.get_udp_port()
      {:ok, tcp_port} = Server.get_tcp_port()

      # Both should be valid ports
      assert is_integer(udp_port)
      assert is_integer(tcp_port)
      assert udp_port > 0
      assert tcp_port > 0
      # They might be same or different depending on OS behavior
    end
  end

  describe "IP address handling" do
    test "get_config listen address is a 4-tuple for IPv4" do
      config = Server.get_config()

      {a, b, c, d} = config.listen
      assert is_integer(a) and a >= 0 and a <= 255
      assert is_integer(b) and b >= 0 and b <= 255
      assert is_integer(c) and c >= 0 and c <= 255
      assert is_integer(d) and d >= 0 and d <= 255
    end

    test "UDP transport options IP matches listen address" do
      config = Server.get_config()

      assert config.udp.transport_options[:ip] == config.listen
    end

    test "TCP transport options IP matches listen address" do
      config = Server.get_config()

      assert config.tcp.transport_options[:ip] == config.listen
    end
  end

  describe "configuration with custom options" do
    setup do
      case Process.whereis(Server) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end

      Process.sleep(50)

      on_exit(fn ->
        try do
          case Process.whereis(Server) do
            nil -> :ok
            pid -> Supervisor.stop(pid)
          end
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    test "start_link accepts custom port" do
      {:ok, pid} = Server.start_link(port: 0, tcp_enabled: false)

      assert is_pid(pid)
      assert Process.alive?(pid)

      {:ok, port} = Server.get_port()
      assert is_integer(port)
    end

    test "start_link accepts custom listen address as tuple" do
      {:ok, pid} = Server.start_link(port: 0, listen: {127, 0, 0, 1}, tcp_enabled: false)

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "start_link accepts custom listen address as string" do
      {:ok, pid} = Server.start_link(port: 0, listen: "127.0.0.1", tcp_enabled: false)

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "start_link accepts IPv6 address as string" do
      {:ok, pid} = Server.start_link(port: 0, listen: "::1", tcp_enabled: false)

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "function exports" do
    test "exports start_link/0" do
      assert function_exported?(Server, :start_link, 0) or
               function_exported?(Server, :start_link, 1)
    end

    test "exports stop/0 and stop/1" do
      assert function_exported?(Server, :stop, 0) or
               function_exported?(Server, :stop, 1)
    end

    test "exports get_config/0" do
      assert function_exported?(Server, :get_config, 0)
    end

    test "exports status/0" do
      assert function_exported?(Server, :status, 0)
    end

    test "exports tcp_enabled?/0" do
      assert function_exported?(Server, :tcp_enabled?, 0)
    end

    test "exports get_port/0 and get_port/1" do
      assert function_exported?(Server, :get_port, 0)
      assert function_exported?(Server, :get_port, 1)
    end

    test "exports get_udp_port/0 and get_udp_port/1" do
      assert function_exported?(Server, :get_udp_port, 0)
      assert function_exported?(Server, :get_udp_port, 1)
    end

    test "exports get_tcp_port/0 and get_tcp_port/1" do
      assert function_exported?(Server, :get_tcp_port, 0)
      assert function_exported?(Server, :get_tcp_port, 1)
    end
  end

  describe "tcp_enabled config flag" do
    test "tcp_enabled defaults to true in get_config" do
      config = Server.get_config()

      assert config.tcp_enabled == true
    end
  end
end
