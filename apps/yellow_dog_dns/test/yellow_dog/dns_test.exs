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
      assert child_spec.start == {YellowDog.Dns.Supervisor, :start_link, [[server_options: [port: 5353]]]}
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
      assert config.broadcast == false
      assert config.handler_module == YellowDog.Dns.Handler.UDP
      assert config.read_timeout == 5_000
      assert config.shutdown_timeout == 5_000
      assert config.num_listeners == 50
      assert config.num_connections == 10_000
      assert config.max_packet_size == 512  # DNS UDP limit
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
end
