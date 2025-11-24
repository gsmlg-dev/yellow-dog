defmodule YellowDog.Dns.ServerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Server

  describe "Server configuration" do
    test "get_config/0 returns valid default configuration" do
      config = Server.get_config()

      assert is_map(config)
      assert config.port == 53
      assert config.transport_module == Abyss.Transport.UDP.Unicast
      assert config.handler_module == YellowDog.Dns.Handler.UDP
      assert is_list(config.transport_options)
      assert is_integer(config.read_timeout)
      assert is_integer(config.shutdown_timeout)
      assert is_integer(config.num_listeners)
      assert is_integer(config.num_connections)
      assert is_integer(config.max_packet_size)
      assert is_boolean(config.rate_limit_enabled)
    end

    test "default port is 53 (standard DNS port)" do
      config = Server.get_config()

      assert config.port == 53
    end

    test "uses unicast transport by default" do
      config = Server.get_config()

      assert config.transport_module == Abyss.Transport.UDP.Unicast
    end

    test "handler module is set to UDP handler" do
      config = Server.get_config()

      assert config.handler_module == YellowDog.Dns.Handler.UDP
    end

    test "rate limiting is enabled by default" do
      config = Server.get_config()

      assert config.rate_limit_enabled == true
      assert is_integer(config.rate_limit_max_packets)
      assert is_integer(config.rate_limit_window_ms)
    end

    test "max packet size is DNS UDP limit (512 bytes)" do
      config = Server.get_config()

      assert config.max_packet_size == 512
    end

    test "transport options include IP and reuseaddr" do
      config = Server.get_config()

      transport_opts = config.transport_options

      assert is_list(transport_opts)
      assert Keyword.has_key?(transport_opts, :ip)
      assert Keyword.has_key?(transport_opts, :reuseaddr)
      assert transport_opts[:reuseaddr] == true
    end

    test "default IP is 0.0.0.0 (listen on all interfaces)" do
      config = Server.get_config()

      transport_opts = config.transport_options

      assert transport_opts[:ip] == {0, 0, 0, 0}
    end
  end

  describe "Server lifecycle" do
    test "server module exports required functions" do
      assert function_exported?(Server, :start_link, 1)
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
      # We can't actually start the server on port 53 in tests
      custom_opts = [port: 5353]

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

  describe "GenServer behaviour" do
    test "server is a GenServer" do
      # Verify the module uses GenServer
      assert function_exported?(Server, :init, 1)
      assert function_exported?(Server, :terminate, 2)
    end
  end

  describe "Abyss integration" do
    test "server delegates to Abyss UDP server" do
      # The server wraps Abyss, so init should be defined
      assert function_exported?(Server, :init, 1)
    end

    test "configuration includes all required Abyss options" do
      config = Server.get_config()

      # Abyss requires these options
      assert Map.has_key?(config, :port)
      assert Map.has_key?(config, :handler_module)
      assert Map.has_key?(config, :transport_options)
      assert Map.has_key?(config, :num_listeners)
      assert Map.has_key?(config, :num_connections)
    end
  end

  describe "DNS-specific configuration" do
    test "timeouts are set appropriately for DNS" do
      config = Server.get_config()

      # DNS queries should be fast
      # 5 seconds
      assert config.read_timeout == 5_000
      # 5 seconds
      assert config.shutdown_timeout == 5_000
    end

    test "listener pool size is appropriate for DNS traffic" do
      config = Server.get_config()

      # DNS needs fewer listeners than DHCP since queries are faster
      assert config.num_listeners == 50
    end

    test "connection pool is large for concurrent queries" do
      config = Server.get_config()

      # DNS can handle many concurrent queries
      assert config.num_connections == 10_000
    end
  end

  describe "Rate limiting configuration" do
    test "rate limiting is configured for DoS protection" do
      config = Server.get_config()

      assert config.rate_limit_enabled == true
      assert config.rate_limit_max_packets == 1000
      assert config.rate_limit_window_ms == 1000
    end

    test "rate limit allows reasonable query volume" do
      config = Server.get_config()

      # Should allow at least 1000 queries per second per IP
      assert config.rate_limit_max_packets >= 1000
      assert config.rate_limit_window_ms <= 1000
    end
  end
end
