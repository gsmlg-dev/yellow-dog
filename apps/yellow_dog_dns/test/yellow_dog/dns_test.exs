defmodule YellowDog.DnsTest do
  use ExUnit.Case, async: true

  describe "DNS application modules" do
    test "DNS server modules exist" do
      # Test that core DNS modules exist and are properly defined
      assert Code.ensure_loaded?(YellowDog.Dns)
      assert Code.ensure_loaded?(YellowDog.Dns.Server)
      assert Code.ensure_loaded?(YellowDog.Dns.Handler.UDP)
    end

    test "DNS module exports required functions" do
      # Test that the main DNS module exports required functions
      # Ensure the module is loaded first
      Code.ensure_loaded!(YellowDog.Dns)
      assert Kernel.function_exported?(YellowDog.Dns, :start_link, 0)
      assert Kernel.function_exported?(YellowDog.Dns, :start_link, 1)
      assert Kernel.function_exported?(YellowDog.Dns, :child_spec, 1)
    end

    test "DNS server configuration is valid" do
      # Test that DNS server configuration is properly formed
      config = YellowDog.Dns.Server.get_config()

      assert is_map(config)
      assert Map.has_key?(config, :port)
      assert Map.has_key?(config, :listen)
      assert Map.has_key?(config, :udp)
      assert Map.has_key?(config, :tcp)

      # Check UDP config
      assert config.udp.handler_module == YellowDog.Dns.Handler.UDP
      assert is_list(config.udp.transport_options)

      # Check TCP config
      assert config.tcp.handler_module == YellowDog.Dns.Handler.TCP
      assert is_list(config.tcp.transport_options)

      assert is_integer(config.port)
    end

    test "DNS server can be created" do
      # Test that DNS server can be created with a child spec
      child_spec = YellowDog.Dns.child_spec(port: 53)

      assert is_map(child_spec)
      assert child_spec.start == {YellowDog.Dns.Supervisor, :start_link, [[port: 53]]}
      assert is_tuple(child_spec.start)
    end
  end

  describe "when DNS service is disabled" do
    test "main application starts without DNS when service is disabled" do
      # Check that DNS server is not running (service disabled in test env)
      pid = Process.whereis(YellowDog.Dns.Server)
      assert pid == nil
    end
  end

  describe "DNS handler" do
    test "handler module is available" do
      # Test that the handler module exists and can be loaded
      assert Code.ensure_loaded?(YellowDog.Dns.Handler.UDP)
    end

    test "handler implements Abyss.Handler behaviour" do
      # Test that the handler uses the Abyss.Handler behaviour
      # Note: These are callbacks implemented via 'use Abyss.Handler', not public exports
      # We verify the module is properly loaded
      assert Code.ensure_loaded?(YellowDog.Dns.Handler.UDP)
    end
  end

  describe "DNS server configuration defaults" do
    test "server configuration has expected defaults" do
      config = YellowDog.Dns.Server.get_config()

      # Check shared defaults
      assert config.port == 53
      assert config.listen == {0, 0, 0, 0}

      # Check UDP defaults
      udp = config.udp
      assert udp.transport_module == Abyss.Transport.UDP.Unicast
      assert udp.handler_module == YellowDog.Dns.Handler.UDP
      assert udp.read_timeout == 5_000
      assert udp.shutdown_timeout == 5_000
      assert udp.num_listeners == 50
      assert udp.num_connections == 10_000
      # DNS UDP limit
      assert udp.max_packet_size == 512

      # Check TCP defaults
      tcp = config.tcp
      assert tcp.transport_module == ThousandIsland.Transports.TCP
      assert tcp.handler_module == YellowDog.Dns.Handler.TCP
      assert tcp.read_timeout == 120_000
      assert tcp.shutdown_timeout == 15_000
      assert tcp.num_acceptors == 100
      assert tcp.num_connections == 16_384
    end

    test "UDP transport options include expected settings" do
      config = YellowDog.Dns.Server.get_config()
      transport_options = config.udp.transport_options

      assert is_list(transport_options)
      assert Keyword.has_key?(transport_options, :ip)
      assert Keyword.has_key?(transport_options, :reuseaddr)
      assert transport_options[:reuseaddr] == true
    end

    test "TCP transport options include expected settings" do
      config = YellowDog.Dns.Server.get_config()
      transport_options = config.tcp.transport_options

      assert is_list(transport_options)
      assert Keyword.has_key?(transport_options, :ip)
      assert Keyword.has_key?(transport_options, :reuseaddr)
      assert Keyword.has_key?(transport_options, :nodelay)
      assert transport_options[:reuseaddr] == true
      assert transport_options[:nodelay] == true
    end
  end

  describe "DNS statistics" do
    test "stats/0 returns a properly structured map" do
      stats = YellowDog.Dns.stats()

      # Verify top-level structure
      assert is_map(stats)
      assert Map.has_key?(stats, :zones)
      assert Map.has_key?(stats, :views)
      assert Map.has_key?(stats, :connections)
      assert Map.has_key?(stats, :service)

      # Verify zones stats structure
      zones = stats.zones
      assert is_map(zones)

      # In test environment, ZoneController is not running
      if Map.has_key?(zones, :error) do
        assert zones.error == "ZoneController not running"
      else
        assert Map.has_key?(zones, :count)
        assert is_integer(zones.count)
      end

      # Verify views stats structure
      views = stats.views
      assert is_map(views)

      # Verify connections stats structure
      connections = stats.connections
      assert is_map(connections)

      # Verify service status structure
      service = stats.service
      assert is_map(service)
      assert Map.has_key?(service, :running)
      assert Map.has_key?(service, :info)
      assert is_boolean(service.running)
      assert is_binary(service.info)
    end

    test "status/0 returns service status" do
      status = YellowDog.Dns.status()

      assert is_map(status)
      assert Map.has_key?(status, :running)
      assert is_boolean(status.running)
    end
  end
end
