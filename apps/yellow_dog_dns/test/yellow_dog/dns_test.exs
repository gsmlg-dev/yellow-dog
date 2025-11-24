defmodule YellowDog.DnsTest do
  use ExUnit.Case

  describe "DNS application modules" do
    test "DNS supervisor and server modules exist" do
      # Test that core DNS modules exist and are properly defined
      assert Code.ensure_loaded?(YellowDog.Dns) == true
      assert Code.ensure_loaded?(YellowDog.Dns.Supervisor) == true
      assert Code.ensure_loaded?(YellowDog.Dns.Server) == true
      assert Code.ensure_loaded?(YellowDog.Dns.Handler.UDP) == true
    end

    test "DNS module exports required functions" do
      # Test that the main DNS module exports required functions
      # Ensure the module is loaded first
      assert Code.ensure_loaded?(YellowDog.Dns) == true
      assert function_exported?(YellowDog.Dns, :start_link, 1)
      assert function_exported?(YellowDog.Dns, :child_spec, 1)
    end

    test "DNS server configuration is valid" do
      # Test that DNS server configuration is properly formed
      config = YellowDog.Dns.Server.get_config()

      assert is_map(config)
      assert Map.has_key?(config, :port)
      assert Map.has_key?(config, :handler_module)
      assert Map.has_key?(config, :transport_options)
      assert config.handler_module == YellowDog.Dns.Handler.UDP
      assert is_integer(config.port)
      assert is_list(config.transport_options)
    end

    test "DNS supervisor can be created" do
      # Test that DNS supervisor can be created with a child spec
      child_spec = YellowDog.Dns.child_spec(server_options: [port: 5353])

      assert is_map(child_spec)

      assert child_spec.start ==
               {YellowDog.Dns.Supervisor, :start_link, [[server_options: [port: 5353]]]}

      assert is_tuple(child_spec.start)
    end
  end

  describe "when DNS service is disabled" do
    test "main application starts without DNS when service is disabled" do
      # Check that DNS supervisor is not running (service disabled in test env)
      pid = Process.whereis(YellowDog.Dns)
      assert pid == nil
    end
  end

  describe "DNS handler" do
    test "handler module is available" do
      # Test that the handler module exists and can be loaded
      assert Code.ensure_loaded?(YellowDog.Dns.Handler.UDP) == true
    end

    test "handler implements Abyss.Handler behaviour" do
      # Test that the handler uses the Abyss.Handler behaviour
      # Note: These are callbacks implemented via 'use Abyss.Handler', not public exports
      # We verify the module is properly loaded
      assert Code.ensure_loaded?(YellowDog.Dns.Handler.UDP) == true
    end
  end

  describe "DNS server configuration defaults" do
    test "server configuration has expected defaults" do
      config = YellowDog.Dns.Server.get_config()

      # Check default values
      assert config.port == 53
      assert config.transport_module == Abyss.Transport.UDP.Unicast
      assert config.handler_module == YellowDog.Dns.Handler.UDP
      assert config.read_timeout == 5_000
      assert config.shutdown_timeout == 5_000
      assert config.num_listeners == 50
      assert config.num_connections == 10_000
      # DNS UDP limit
      assert config.max_packet_size == 512
      assert config.rate_limit_enabled == true
    end

    test "transport options include expected settings" do
      config = YellowDog.Dns.Server.get_config()
      transport_options = config.transport_options

      assert is_list(transport_options)
      assert Keyword.has_key?(transport_options, :ip)
      assert Keyword.has_key?(transport_options, :reuseaddr)
      assert transport_options[:reuseaddr] == true
    end
  end

  describe "DNS statistics" do
    test "stats/0 returns a properly structured map" do
      stats = YellowDog.Dns.stats()

      # Verify top-level structure
      assert is_map(stats)
      assert Map.has_key?(stats, :zones)
      assert Map.has_key?(stats, :storage)
      assert Map.has_key?(stats, :service)

      # Verify storage stats structure (may be error if not initialized)
      storage = stats.storage
      assert is_map(storage)

      if Map.has_key?(storage, :error) do
        # Storage not initialized - this is expected in test environment
        assert storage.error == "Storage not initialized"
      else
        # Storage initialized - verify structure
        assert Map.has_key?(storage, :total_zones)
        assert Map.has_key?(storage, :total_records)
        assert Map.has_key?(storage, :memory_bytes)
        assert Map.has_key?(storage, :memory_mb)
        assert is_integer(storage.total_zones)
        assert is_integer(storage.total_records)
        assert is_integer(storage.memory_bytes)
        assert is_float(storage.memory_mb)
      end

      # Verify service status structure
      service = stats.service
      assert is_map(service)
      assert Map.has_key?(service, :running)
      assert Map.has_key?(service, :info)
      assert is_boolean(service.running)
      assert is_binary(service.info)

      # Verify zones stats structure (either error or valid stats)
      zones = stats.zones
      assert is_map(zones)

      # In test environment, zone manager is not running
      if Map.has_key?(zones, :error) do
        assert zones.error in ["Zone manager not running", "Zone manager not available"]
      else
        # If running, verify structure
        assert Map.has_key?(zones, :loaded_zones)
        assert is_integer(zones.loaded_zones)
      end
    end

    test "status/0 returns service status" do
      status = YellowDog.Dns.status()

      assert is_map(status)
      assert Map.has_key?(status, :running)
      assert is_boolean(status.running)
    end
  end
end
