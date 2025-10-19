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

    test "DNS supporting modules exist" do
      # Test that supporting modules exist
      assert Code.ensure_loaded?(YellowDog.Dns.ViewManager) == true
      assert Code.ensure_loaded?(YellowDog.Dns.NameResolver) == true
      assert Code.ensure_loaded?(YellowDog.Dns.View) == true
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
      # Start the main application - DNS should be disabled in test environment
      {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

      # Check that DNS supervisor is not running (service disabled in test env)
      pid = Process.whereis(YellowDog.Dns)
      assert pid == nil

      # Check that ViewManager is not started
      assert Process.whereis(YellowDog.Dns.ViewManager) == nil

      # Check that NameResolver is not started
      assert Process.whereis(YellowDog.Dns.NameResolver) == nil
    end
  end

  test "DNS modules are available" do
    # Test that DNS modules can be loaded and used
    # Ensure the main DNS module is loaded first
    assert Code.ensure_loaded?(YellowDog.Dns) == true
    assert function_exported?(YellowDog.Dns, :start_link, 1)
    assert function_exported?(YellowDog.Dns, :child_spec, 1)

    # Test that ViewManager and NameResolver modules exist and can be loaded
    view_manager_loaded = Code.ensure_loaded?(YellowDog.Dns.ViewManager)
    name_resolver_loaded = Code.ensure_loaded?(YellowDog.Dns.NameResolver)

    # Code.ensure_loaded? returns true if module is loaded, false otherwise
    assert view_manager_loaded == true
    assert name_resolver_loaded == true
  end

  test "DNS server configuration is valid" do
    # Test that DNS server configuration is properly formed
    config = YellowDog.Dns.Server.get_config()

    assert is_map(config)
    assert Map.has_key?(config, :port)
    assert Map.has_key?(config, :handler_module)
    assert Map.has_key?(config, :transport_options)
    assert config.handler_module == YellowDog.Dns.Handler.UDP
  end
end
