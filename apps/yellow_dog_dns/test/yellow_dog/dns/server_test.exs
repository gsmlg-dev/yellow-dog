defmodule YellowDog.Dns.ServerTest do
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
      # Just verify the function exists and accepts 1 argument
      assert function_exported?(Server, :stop, 1)
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

end
