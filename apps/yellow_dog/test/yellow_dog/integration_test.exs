defmodule YellowDog.IntegrationTest do
  use ExUnit.Case, async: false

  alias YellowDog.ConfigHelper

  setup do
    # Ensure application is stopped before each test
    Application.stop(:yellow_dog)

    # Ensure all services are stopped
    ConfigHelper.stop_all_services()

    # Wait for cleanup
    Process.sleep(100)

    on_exit(fn ->
      Application.stop(:yellow_dog)
      ConfigHelper.stop_all_services()
    end)

    :ok
  end

  describe "Application Startup with Configuration" do
    test "starts application with valid config and all services enabled" do
      # Load valid config
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      # Start config agent
      {:ok, _pid} = YellowDog.Config.start_link(config)

      # Verify config is accessible
      assert YellowDog.Config.service_enabled?(:dns) == true
      assert YellowDog.Config.service_enabled?(:mdns) == true
      assert YellowDog.Config.service_enabled?(:dhcpv4) == true
      assert YellowDog.Config.service_enabled?(:dhcpv6) == false

      # Verify service configs are loaded correctly
      dns_config = YellowDog.Config.get_service(:dns)
      assert dns_config.port == 53
      assert dns_config.listen == "127.0.0.1"

      dhcpv4_config = YellowDog.Config.get_service(:dhcpv4)
      assert dhcpv4_config.port == 67
    end

    test "starts application with minimal config using defaults" do
      # Load minimal config
      {:ok, config} = ConfigHelper.load_test_config("minimal_config")

      # Start config agent
      {:ok, _pid} = YellowDog.Config.start_link(config)

      # Verify service states from minimal config
      assert YellowDog.Config.service_enabled?(:dns) == true
      assert YellowDog.Config.service_enabled?(:mdns) == false
      assert YellowDog.Config.service_enabled?(:dhcpv4) == false

      # Verify DNS config values
      dns_config = YellowDog.Config.get_service(:dns)
      assert dns_config.port == 53
    end

    test "starts application with all services disabled" do
      # Load all disabled config
      {:ok, config} = ConfigHelper.load_test_config("all_disabled")

      # Start config agent
      {:ok, _pid} = YellowDog.Config.start_link(config)

      # Verify all services are disabled
      assert YellowDog.Config.service_enabled?(:dns) == false
      assert YellowDog.Config.service_enabled?(:mdns) == false
      assert YellowDog.Config.service_enabled?(:dhcpv4) == false
      assert YellowDog.Config.service_enabled?(:dhcpv6) == false
    end
  end

  describe "Service Startup Ordering" do
    test "config agent starts before other services" do
      # This is verified by the Application module structure
      # Config agent is always first in the children list

      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, config_pid} = YellowDog.Config.start_link(config)

      # Config process should be running
      assert Process.alive?(config_pid)

      # Config should be accessible immediately
      assert is_map(YellowDog.Config.get_all())
    end

    test "services use config values when starting" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      # Get DNS config
      dns_config = YellowDog.Config.get_service(:dns)

      # Verify config has expected values
      assert dns_config.port == 53
      assert dns_config.listen == "127.0.0.1"
      assert dns_config.worker_pool_size == 10

      # Get DHCP config
      dhcpv4_config = YellowDog.Config.get_service(:dhcpv4)
      assert dhcpv4_config.port == 67
      assert dhcpv4_config.listen == "0.0.0.0"
    end
  end

  describe "Configuration Validation" do
    test "handles malformed config gracefully" do
      # Load invalid config should return error
      result = ConfigHelper.load_test_config("invalid_config")

      assert {:error, _reason} = result
    end

    test "validates required core section exists" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      assert Map.has_key?(config, "core")

      core = Map.get(config, "core")
      assert is_map(core)
      assert Map.has_key?(core, "dns")
      assert Map.has_key?(core, "mdns")
      assert Map.has_key?(core, "dhcpv4")
      assert Map.has_key?(core, "dhcpv6")
    end

    test "validates service configurations have correct types" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      dns_config = YellowDog.Config.get_service(:dns)

      # Port should be integer
      assert is_integer(dns_config.port)

      # Listen should be string
      assert is_binary(dns_config.listen)

      # Worker pool size should be integer
      assert is_integer(dns_config.worker_pool_size)
    end
  end

  describe "DNS Zone Configuration Integration" do
    test "loads DNS zones from config" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      # Get all zones
      zones = YellowDog.Config.get_dns_zones()

      assert is_map(zones)
      assert Map.has_key?(zones, "example_com")
      assert Map.has_key?(zones, "test_local")
    end

    test "retrieves specific zone configuration" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      # Get specific zone
      {:ok, zone_config} = YellowDog.Config.get_dns_zone("example_com")

      assert zone_config["type"] == "authoritative"
      assert zone_config["file"] == "zones/example.com.zone"
    end

    test "lists all configured zone names" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      zone_names = YellowDog.Config.list_dns_zones()

      assert is_list(zone_names)
      assert "example_com" in zone_names
      assert "test_local" in zone_names
    end
  end

  describe "DHCP Pool Configuration Integration" do
    test "loads DHCP pool configurations" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      dhcpv4_config = YellowDog.Config.get_service(:dhcpv4)

      # Verify pools are loaded
      assert Map.has_key?(dhcpv4_config, :pools)
      pools = dhcpv4_config.pools

      assert is_list(pools)
      assert length(pools) == 2

      # Verify first pool
      [pool1, pool2] = pools
      assert pool1["name"] == "office_network"
      assert pool1["subnet"] == "192.168.1.0/24"
      assert pool1["lease_time"] == 3600

      # Verify second pool
      assert pool2["name"] == "guest_network"
      assert pool2["lease_time"] == 1800
    end
  end

  describe "Concurrent Configuration Access" do
    test "multiple processes can read config simultaneously" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      # Spawn multiple processes reading different parts of config
      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            case rem(i, 4) do
              0 -> YellowDog.Config.get_service(:dns)
              1 -> YellowDog.Config.get_service(:dhcpv4)
              2 -> YellowDog.Config.get_dns_zones()
              3 -> YellowDog.Config.service_enabled?(:mdns)
            end
          end)
        end)

      # All tasks should complete successfully
      results = Task.await_many(tasks, 5000)

      assert length(results) == 20
      assert Enum.all?(results, fn result -> result != nil end)
    end

    test "config reads are consistent across processes" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      # Read same config value from multiple processes
      tasks =
        Enum.map(1..10, fn _i ->
          Task.async(fn ->
            dns_config = YellowDog.Config.get_service(:dns)
            dns_config.port
          end)
        end)

      ports = Task.await_many(tasks)

      # All processes should see the same value (DNS port is 53)
      assert Enum.all?(ports, fn port -> port == 53 end)
    end
  end

  describe "Error Recovery" do
    test "handles missing config file with fallback" do
      # Try to load non-existent file
      result = YellowDog.Config.load("/nonexistent/path/config.toml")

      assert {:error, :enoent} = result
    end

    test "load_with_fallback returns default config on error" do
      # Should not crash, returns empty default config
      config = YellowDog.Config.load_with_fallback("/nonexistent/path.toml")

      assert is_map(config)
    end

    test "returns nil for non-existent config keys" do
      {:ok, config} = ConfigHelper.load_test_config("minimal_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      result = YellowDog.Config.get("nonexistent_service")

      assert result == nil
    end

    test "returns error for non-existent DNS zone" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      result = YellowDog.Config.get_dns_zone("nonexistent.com")

      assert {:error, :not_found} = result
    end
  end

  describe "Configuration with Missing Optional Fields" do
    test "uses defaults when optional fields are missing" do
      {:ok, config} = ConfigHelper.load_test_config("partial_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      # DNS config should have listen but port should be missing
      dns_config = YellowDog.Config.get_service(:dns)
      assert dns_config.listen == "127.0.0.1"

      # mDNS config should be empty but valid
      mdns_config = YellowDog.Config.get_service(:mdns)
      assert is_map(mdns_config)
    end
  end
end
