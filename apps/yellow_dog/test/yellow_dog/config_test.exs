defmodule YellowDog.ConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.ConfigHelper

  setup do
    # Ensure config agent is stopped before each test
    case Process.whereis(YellowDog.Config) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        # Wait until the process is actually dead and name is unregistered
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1000 -> :ok
        end

        # Additional polling to ensure name is unregistered
        wait_for_unregister(YellowDog.Config, 100)
    end

    :ok
  end

  defp wait_for_unregister(name, max_attempts) do
    case Process.whereis(name) do
      nil ->
        :ok

      _pid when max_attempts > 0 ->
        Process.sleep(10)
        wait_for_unregister(name, max_attempts - 1)

      _pid ->
        :timeout
    end
  end

  describe "Config Loading" do
    test "successfully loads valid TOML config file" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      assert is_map(config)
      assert Map.has_key?(config, "core")
      assert Map.has_key?(config, "dns")
      assert Map.has_key?(config, "dhcpv4")
    end

    test "handles missing config file with error" do
      result = YellowDog.Config.load("/nonexistent/path/config.toml")

      assert {:error, :enoent} = result
    end

    test "handles malformed TOML with error" do
      {:error, reason} = ConfigHelper.load_test_config("invalid_config")

      assert reason != nil
    end

    test "loads minimal config with defaults" do
      {:ok, config} = ConfigHelper.load_test_config("minimal_config")

      assert is_map(config)
      assert Map.has_key?(config, "core")
      assert Map.get(config, "core") |> Map.get("dns") == true
    end

    test "loads config with all services disabled" do
      {:ok, config} = ConfigHelper.load_test_config("all_disabled")

      core_config = Map.get(config, "core")
      assert core_config["dns"] == false
      assert core_config["mdns"] == false
      assert core_config["dhcpv4"] == false
      assert core_config["dhcpv6"] == false
    end
  end

  describe "Config Parsing" do
    test "parses service configurations correctly" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      dns_config = Map.get(config, "dns")
      assert dns_config["port"] == 53
      assert dns_config["listen"] == "127.0.0.1"
      assert dns_config["worker_pool_size"] == 10
    end

    test "parses nested configurations (zones)" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      dns_config = Map.get(config, "dns")
      zones = Map.get(dns_config, "zones")

      assert is_map(zones)
      assert Map.has_key?(zones, "example_com")
      assert Map.has_key?(zones, "test_local")

      example_zone = Map.get(zones, "example_com")
      assert example_zone["type"] == "authoritative"
      assert example_zone["file"] == "zones/example.com.zone"
    end

    test "parses nested configurations (DHCP pools)" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      dhcp_config = Map.get(config, "dhcpv4")
      pools = Map.get(dhcp_config, "pools")

      assert is_list(pools)
      assert length(pools) == 2

      [pool1, pool2] = pools
      assert pool1["name"] == "office_network"
      assert pool1["subnet"] == "192.168.1.0/24"
      assert pool1["lease_time"] == 3600

      assert pool2["name"] == "guest_network"
      assert pool2["lease_time"] == 1800
    end

    test "handles missing optional fields with defaults" do
      {:ok, config} = ConfigHelper.load_test_config("partial_config")

      # DNS config should have defaults for missing fields
      dns_config = Map.get(config, "dns")
      assert dns_config["listen"] == "127.0.0.1"
      # Port should be missing, will use default when accessed

      # mDNS config should be empty but valid
      mdns_config = Map.get(config, "mdns")
      assert is_map(mdns_config)
    end

    test "validates required core section exists" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      assert Map.has_key?(config, "core")
      core = Map.get(config, "core")
      assert is_map(core)
    end
  end

  describe "Config Access via Agent" do
    setup do
      # Ensure config agent is stopped before starting
      case Process.whereis(YellowDog.Config) do
        nil ->
          :ok

        pid ->
          Process.exit(pid, :kill)
          # Wait until the process is actually dead
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            1000 -> :ok
          end

          # Additional polling to ensure name is unregistered
          wait_for_unregister(YellowDog.Config, 100)
      end

      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      on_exit(fn ->
        case Process.whereis(YellowDog.Config) do
          nil -> :ok
          pid -> Process.exit(pid, :kill)
        end
      end)

      {:ok, config: config}
    end

    test "get_all/0 returns complete config tree" do
      config = YellowDog.Config.get_all()

      assert is_map(config)
      assert Map.has_key?(config, "core")
      assert Map.has_key?(config, "dns")
    end

    test "get/1 returns specific service config" do
      dns_config = YellowDog.Config.get("dns")

      assert is_map(dns_config)
      assert dns_config["port"] == 53
    end

    test "get_service/1 returns service config with atom keys" do
      dns_config = YellowDog.Config.get_service(:dns)

      assert is_map(dns_config)
      assert Map.has_key?(dns_config, :port)
      assert dns_config.port == 53
    end

    test "get/2 returns specific config value for service" do
      port = YellowDog.Config.get(:dns, :port)

      assert port == 53
    end

    test "service_enabled?/1 correctly identifies enabled services" do
      assert YellowDog.Config.service_enabled?(:dns) == true
      assert YellowDog.Config.service_enabled?(:mdns) == true
      assert YellowDog.Config.service_enabled?(:dhcpv4) == true
      assert YellowDog.Config.service_enabled?(:dhcpv6) == false
    end

    test "concurrent access to config from multiple processes" do
      # Spawn multiple processes that read config simultaneously
      tasks =
        Enum.map(1..10, fn _i ->
          Task.async(fn ->
            YellowDog.Config.get_service(:dns)
          end)
        end)

      # All tasks should complete successfully
      results = Task.await_many(tasks)

      assert length(results) == 10
      assert Enum.all?(results, fn config -> is_map(config) and config.port == 53 end)
    end
  end

  describe "DNS Zone Configuration" do
    setup do
      # Ensure config agent is stopped before starting
      case Process.whereis(YellowDog.Config) do
        nil ->
          :ok

        pid ->
          Process.exit(pid, :kill)
          # Wait until the process is actually dead
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            1000 -> :ok
          end

          # Additional polling to ensure name is unregistered
          wait_for_unregister(YellowDog.Config, 100)
      end

      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      on_exit(fn ->
        case Process.whereis(YellowDog.Config) do
          nil -> :ok
          pid -> Process.exit(pid, :kill)
        end
      end)

      :ok
    end

    test "get_dns_zones/0 returns all configured zones" do
      zones = YellowDog.Config.get_dns_zones()

      assert is_map(zones)
      assert Map.has_key?(zones, "example_com")
      assert Map.has_key?(zones, "test_local")
    end

    test "get_dns_zone/1 returns specific zone config" do
      {:ok, zone_config} = YellowDog.Config.get_dns_zone("example_com")

      assert is_map(zone_config)
      assert zone_config["type"] == "authoritative"
      assert zone_config["file"] == "zones/example.com.zone"
    end

    test "get_dns_zone/1 returns error for non-existent zone" do
      result = YellowDog.Config.get_dns_zone("nonexistent.com")

      assert {:error, :not_found} = result
    end

    test "list_dns_zones/0 returns list of zone names" do
      zones = YellowDog.Config.list_dns_zones()

      assert is_list(zones)
      assert "example_com" in zones
      assert "test_local" in zones
    end

    test "dns_zone_enabled?/1 checks if zone is configured" do
      assert YellowDog.Config.dns_zone_enabled?("example_com") == true
      assert YellowDog.Config.dns_zone_enabled?("nonexistent.com") == false
    end

    test "get_dns_zone_type/1 returns zone type" do
      {:ok, type} = YellowDog.Config.get_dns_zone_type("example_com")

      assert type == :authoritative
    end

    test "get_dns_zone_file/1 returns zone file path" do
      {:ok, file_path} = YellowDog.Config.get_dns_zone_file("example_com")

      assert file_path == "zones/example.com.zone"
    end
  end

  describe "Type Validation" do
    test "ports are integers" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      dns_port = get_in(config, ["dns", "port"])
      dhcp_port = get_in(config, ["dhcpv4", "port"])

      assert is_integer(dns_port)
      assert is_integer(dhcp_port)
    end

    test "interfaces/listen addresses are strings" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      dns_listen = get_in(config, ["dns", "listen"])
      dhcp_listen = get_in(config, ["dhcpv4", "listen"])

      assert is_binary(dns_listen)
      assert is_binary(dhcp_listen)
    end

    test "pool configurations are lists" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      pools = get_in(config, ["dhcpv4", "pools"])

      assert is_list(pools)
      assert length(pools) > 0
    end

    test "enabled flags are booleans" do
      {:ok, config} = ConfigHelper.load_test_config("valid_config")

      core = Map.get(config, "core")
      assert is_boolean(core["dns"])
      assert is_boolean(core["mdns"])
      assert is_boolean(core["dhcpv4"])
      assert is_boolean(core["dhcpv6"])
    end
  end

  describe "Error Handling" do
    test "load_with_fallback/1 uses defaults on error" do
      config = YellowDog.Config.load_with_fallback("/nonexistent/path.toml")

      # Should return empty default config map
      assert is_map(config)
    end

    test "get/1 returns nil for non-existent keys" do
      # Ensure config agent is stopped before starting
      case Process.whereis(YellowDog.Config) do
        nil ->
          :ok

        pid ->
          Process.exit(pid, :kill)
          # Wait until the process is actually dead
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            1000 -> :ok
          end

          # Additional polling to ensure name is unregistered
          wait_for_unregister(YellowDog.Config, 100)
      end

      {:ok, config} = ConfigHelper.load_test_config("minimal_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      result = YellowDog.Config.get("nonexistent_service")

      assert result == nil
    end
  end

  describe "Configuration Updates (update/2, compare_and_swap/3)" do
    setup do
      # Ensure config agent is stopped
      case Process.whereis(YellowDog.Config) do
        nil -> :ok
        pid -> Process.exit(pid, :kill)
      end

      wait_for_unregister(YellowDog.Config, 100)

      # Start with test config
      {:ok, config} = ConfigHelper.load_test_config("valid_config")
      {:ok, _pid} = YellowDog.Config.start_link(config)

      on_exit(fn ->
        case Process.whereis(YellowDog.Config) do
          nil -> :ok
          pid -> Process.exit(pid, :kill)
        end
      end)

      :ok
    end

    test "update/2 updates service configuration" do
      new_config = %{"port" => 5353, "listen" => "127.0.0.1"}

      assert :ok = YellowDog.Config.update(:dns, new_config)

      # Verify update applied
      updated = YellowDog.Config.get_service(:dns)
      assert updated[:port] == 5353
      assert updated[:listen] == "127.0.0.1"
    end

    test "update/2 preserves other services" do
      original_mdns = YellowDog.Config.get_service(:mdns)

      YellowDog.Config.update(:dns, %{"port" => 9999})

      # Verify mDNS unchanged
      mdns_config = YellowDog.Config.get_service(:mdns)
      assert mdns_config == original_mdns
    end

    test "compare_and_swap/3 updates when version matches" do
      current_version = YellowDog.Config.get_version()

      new_config = %{"port" => 8080, "listen" => "0.0.0.0"}

      assert :ok = YellowDog.Config.compare_and_swap(:dns, new_config, current_version)

      # Verify update applied
      updated = YellowDog.Config.get_service(:dns)
      assert updated[:port] == 8080

      # Verify version incremented
      assert YellowDog.Config.get_version() == current_version + 1
    end

    test "compare_and_swap/3 rejects update with mismatched version" do
      current_version = YellowDog.Config.get_version()
      original_dns = YellowDog.Config.get_service(:dns)

      new_config = %{"port" => 8080}

      # Try to update with wrong version
      assert {:error, :version_mismatch} =
               YellowDog.Config.compare_and_swap(:dns, new_config, current_version + 99)

      # Verify update NOT applied
      dns_config = YellowDog.Config.get_service(:dns)
      assert dns_config == original_dns

      # Verify version unchanged
      assert YellowDog.Config.get_version() == current_version
    end

    test "get_version/0 returns current version" do
      version = YellowDog.Config.get_version()
      assert is_integer(version)
      assert version >= 0
    end

    test "optimistic locking workflow simulates concurrent administrators" do
      # Simulate two administrators loading the page
      version_admin_a = YellowDog.Config.get_version()
      version_admin_b = YellowDog.Config.get_version()

      assert version_admin_a == version_admin_b

      # Admin A saves first (succeeds)
      assert :ok = YellowDog.Config.compare_and_swap(:dns, %{"port" => 53}, version_admin_a)

      # Admin B tries to save with stale version (fails)
      assert {:error, :version_mismatch} =
               YellowDog.Config.compare_and_swap(:dns, %{"port" => 8080}, version_admin_b)

      # Admin B reloads page and gets new version
      version_admin_b_reload = YellowDog.Config.get_version()

      # Admin B saves again with correct version (succeeds)
      assert :ok =
               YellowDog.Config.compare_and_swap(:dns, %{"port" => 8080}, version_admin_b_reload)

      # Verify final state
      dns_config = YellowDog.Config.get_service(:dns)
      assert dns_config[:port] == 8080
    end
  end
end
