defmodule YellowDog.MdnsTest do
  @moduledoc """
  Comprehensive unit tests for the YellowDog.Mdns public API facade.

  Tests cover:
  - Service registration API
  - Network discovery API
  - Cache API
  - Status API
  - Module delegation patterns
  """
  use ExUnit.Case, async: false

  alias YellowDog.Mdns
  alias YellowDog.Mdns.{ServiceRegistry, NetworkMonitor, MessageCache}

  # Start required processes once for all tests
  # Track whether we started them so we can clean up properly
  setup_all do
    # Start ServiceRegistry if not started
    {registry_pid, registry_started} =
      case ServiceRegistry.start_link([]) do
        {:ok, pid} -> {pid, true}
        {:error, {:already_started, pid}} -> {pid, false}
      end

    # Start NetworkMonitor if not started
    {monitor_pid, monitor_started} =
      case NetworkMonitor.start_link([]) do
        {:ok, pid} -> {pid, true}
        {:error, {:already_started, pid}} -> {pid, false}
      end

    # Ensure MessageCache ETS table exists
    {cache_pid, cache_started} =
      case MessageCache.start_link([]) do
        {:ok, pid} -> {pid, true}
        {:error, {:already_started, pid}} -> {pid, false}
      end

    # Return cleanup info - only stop processes we started
    on_exit(fn ->
      if registry_started and Process.alive?(registry_pid), do: GenServer.stop(registry_pid, :normal, 100)
      if monitor_started and Process.alive?(monitor_pid), do: GenServer.stop(monitor_pid, :normal, 100)
      if cache_started and Process.alive?(cache_pid), do: GenServer.stop(cache_pid, :normal, 100)
    end)

    {:ok, registry_pid: registry_pid, monitor_pid: monitor_pid, cache_pid: cache_pid}
  end

  # Clear state between tests
  setup do
    try do
      Mdns.clear_cache()
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  describe "module exports" do
    test "exports start_link/1" do
      assert function_exported?(Mdns, :start_link, 1)
    end

    test "exports child_spec/1" do
      assert function_exported?(Mdns, :child_spec, 1)
    end

    test "exports register_service/2" do
      assert function_exported?(Mdns, :register_service, 2)
    end

    test "exports unregister_service/2" do
      assert function_exported?(Mdns, :unregister_service, 2)
    end

    test "exports list_registered_services/1" do
      assert function_exported?(Mdns, :list_registered_services, 1)
    end

    test "exports get_registered_service/1" do
      assert function_exported?(Mdns, :get_registered_service, 1)
    end

    test "exports update_service/3" do
      assert function_exported?(Mdns, :update_service, 3)
    end

    test "exports toggle_service/1" do
      assert function_exported?(Mdns, :toggle_service, 1)
    end

    test "exports list_discovered_services/0" do
      assert function_exported?(Mdns, :list_discovered_services, 0)
    end

    test "exports get_discovered_service/1" do
      assert function_exported?(Mdns, :get_discovered_service, 1)
    end

    test "exports discover_services/1" do
      assert function_exported?(Mdns, :discover_services, 1)
    end

    test "exports network_stats/0" do
      assert function_exported?(Mdns, :network_stats, 0)
    end

    test "exports get_recent_queries/1" do
      assert function_exported?(Mdns, :get_recent_queries, 1)
    end

    test "exports query/2" do
      assert function_exported?(Mdns, :query, 2)
    end

    test "exports list_all/0" do
      assert function_exported?(Mdns, :list_all, 0)
    end

    test "exports stats/0" do
      assert function_exported?(Mdns, :stats, 0)
    end

    test "exports clear_cache/0" do
      assert function_exported?(Mdns, :clear_cache, 0)
    end

    test "exports status/0" do
      assert function_exported?(Mdns, :status, 0)
    end
  end

  describe "service registration" do
    test "register_service/1 with minimal service definition" do
      service_def = %{
        name: "Test Service #{:rand.uniform(1_000_000)}",
        type: "_http._tcp",
        port: 8080
      }

      {:ok, service_id} = Mdns.register_service(service_def)

      assert is_binary(service_id)
      assert String.contains?(service_id, "_http._tcp")
    end

    test "register_service/2 with full service definition" do
      service_def = %{
        name: "Full Service #{:rand.uniform(1_000_000)}",
        type: "_https._tcp",
        port: 443,
        txt: %{"version" => "1.0", "path" => "/api"},
        addresses: ["192.168.1.100", "192.168.1.101"],
        enabled: true
      }

      {:ok, service_id} = Mdns.register_service(service_def, persist: false)

      assert is_binary(service_id)

      # Verify service was registered
      service = Mdns.get_registered_service(service_id)
      assert service != nil
      assert service.name == service_def.name
      assert service.port == 443
    end

    test "register_service/1 returns error for invalid definition" do
      # Missing required fields
      {:error, reason} = Mdns.register_service(%{name: "Invalid"})
      assert reason != nil
    end

    test "list_registered_services/0 returns all services" do
      # Register a service
      name = "List Test #{:rand.uniform(1_000_000)}"
      {:ok, _} = Mdns.register_service(%{name: name, type: "_test._tcp", port: 1234})

      services = Mdns.list_registered_services()

      assert is_list(services)
      assert Enum.any?(services, fn s -> s.name == name end)
    end

    test "list_registered_services/1 with filter option" do
      name = "Filter Test #{:rand.uniform(1_000_000)}"
      {:ok, _} = Mdns.register_service(%{name: name, type: "_filter._tcp", port: 5678, enabled: true})

      # Filter for enabled services
      enabled = Mdns.list_registered_services(filter: :enabled)
      assert is_list(enabled)

      # Filter for all services
      all = Mdns.list_registered_services(filter: :all)
      assert is_list(all)
    end

    test "get_registered_service/1 returns service by ID" do
      name = "Get Test #{:rand.uniform(1_000_000)}"
      {:ok, service_id} = Mdns.register_service(%{name: name, type: "_get._tcp", port: 9999})

      service = Mdns.get_registered_service(service_id)

      assert service != nil
      assert service.name == name
      assert service.port == 9999
    end

    test "get_registered_service/1 returns nil for unknown ID" do
      result = Mdns.get_registered_service("nonexistent-service-id")
      assert result == nil
    end

    test "update_service/2 modifies service" do
      name = "Update Test #{:rand.uniform(1_000_000)}"
      {:ok, service_id} = Mdns.register_service(%{name: name, type: "_update._tcp", port: 1111})

      # Update the port
      :ok = Mdns.update_service(service_id, %{port: 2222})

      # Verify update
      service = Mdns.get_registered_service(service_id)
      assert service.port == 2222
    end

    test "toggle_service/1 toggles enabled state" do
      name = "Toggle Test #{:rand.uniform(1_000_000)}"
      {:ok, service_id} = Mdns.register_service(%{name: name, type: "_toggle._tcp", port: 3333, enabled: true})

      # Get initial state
      service = Mdns.get_registered_service(service_id)
      initial_enabled = service.enabled

      # Toggle
      :ok = Mdns.toggle_service(service_id)

      # Verify toggle
      service = Mdns.get_registered_service(service_id)
      assert service.enabled == not initial_enabled
    end

    test "unregister_service/1 removes service" do
      name = "Unregister Test #{:rand.uniform(1_000_000)}"
      {:ok, service_id} = Mdns.register_service(%{name: name, type: "_unreg._tcp", port: 4444})

      # Verify it exists
      assert Mdns.get_registered_service(service_id) != nil

      # Unregister
      :ok = Mdns.unregister_service(service_id)

      # Verify it's gone
      assert Mdns.get_registered_service(service_id) == nil
    end
  end

  describe "network discovery" do
    test "list_discovered_services/0 returns list" do
      services = Mdns.list_discovered_services()
      assert is_list(services)
    end

    test "get_discovered_service/1 returns nil for unknown" do
      result = Mdns.get_discovered_service("unknown-service")
      assert result == nil
    end

    test "discover_services/0 returns list" do
      services = Mdns.discover_services()
      assert is_list(services)
    end

    test "discover_services/1 accepts filter options" do
      services = Mdns.discover_services(type: "_http._tcp")
      assert is_list(services)
    end

    test "network_stats/0 returns map with expected keys" do
      stats = Mdns.network_stats()

      assert is_map(stats)
      # NetworkMonitor.network_stats should return these keys
      assert Map.has_key?(stats, :total_responses) or Map.has_key?(stats, :total_queries)
    end

    test "get_recent_queries/0 returns list" do
      queries = Mdns.get_recent_queries()
      assert is_list(queries)
    end

    test "get_recent_queries/1 with limit option" do
      queries = Mdns.get_recent_queries(limit: 10)
      assert is_list(queries)
      assert length(queries) <= 10
    end
  end

  describe "cache API" do
    test "query/1 returns list for domain" do
      result = Mdns.query("test.local")
      assert is_list(result)
    end

    test "query/2 with record type filter" do
      result = Mdns.query("test.local", :a)
      assert is_list(result)
    end

    test "list_all/0 returns all cached entries" do
      entries = Mdns.list_all()
      assert is_list(entries)
    end

    test "stats/0 returns statistics map" do
      stats = Mdns.stats()
      assert is_map(stats)
    end

    test "clear_cache/0 clears all caches" do
      # Should not raise
      assert Mdns.clear_cache() == :ok
    end
  end

  describe "status API" do
    test "status/0 returns status map when service not running" do
      # When mDNS supervisor is not running
      # (We don't start the full supervisor in these tests)
      status = Mdns.status()

      assert is_map(status)
      assert Map.has_key?(status, :running)
      assert Map.has_key?(status, :mode)
      assert Map.has_key?(status, :registered_services)
      assert Map.has_key?(status, :discovered_services)
    end

    test "status/0 includes network_stats" do
      status = Mdns.status()
      assert Map.has_key?(status, :network_stats)
    end

    test "status/0 includes registry_stats" do
      status = Mdns.status()
      assert Map.has_key?(status, :registry_stats)
    end
  end

  describe "delegation patterns" do
    test "register_service delegates to ServiceRegistry" do
      # This is verified by the service registration tests
      # but we ensure delegation happens correctly
      name = "Delegate Test #{:rand.uniform(1_000_000)}"
      {:ok, service_id} = Mdns.register_service(%{name: name, type: "_delegate._tcp", port: 5555})

      # ServiceRegistry should have it
      service = ServiceRegistry.get_service(service_id)
      assert service != nil
    end

    test "list_discovered_services delegates to NetworkMonitor" do
      # Both should return the same result
      facade_result = Mdns.list_discovered_services()
      direct_result = NetworkMonitor.list_discovered_services()

      assert facade_result == direct_result
    end

    test "network_stats delegates to NetworkMonitor" do
      facade_result = Mdns.network_stats()
      direct_result = NetworkMonitor.network_stats()

      assert facade_result == direct_result
    end
  end

  describe "edge cases" do
    test "handles empty service list gracefully" do
      # Clear all services first (if possible)
      services = Mdns.list_registered_services()
      # Just verify we get a list, don't assume it's empty
      assert is_list(services)
    end

    test "handles unicode service names" do
      name = "Test 测试 서비스 #{:rand.uniform(1_000_000)}"
      {:ok, service_id} = Mdns.register_service(%{name: name, type: "_unicode._tcp", port: 6666})

      service = Mdns.get_registered_service(service_id)
      assert service.name == name
    end

    test "handles service names with special characters" do
      name = "Test-Service_123 #{:rand.uniform(1_000_000)}"
      {:ok, service_id} = Mdns.register_service(%{name: name, type: "_special._tcp", port: 7777})

      service = Mdns.get_registered_service(service_id)
      assert service.name == name
    end

    test "handles high port numbers" do
      name = "High Port #{:rand.uniform(1_000_000)}"
      {:ok, service_id} = Mdns.register_service(%{name: name, type: "_highport._tcp", port: 65535})

      service = Mdns.get_registered_service(service_id)
      assert service.port == 65535
    end

    test "handles empty TXT records" do
      name = "Empty TXT #{:rand.uniform(1_000_000)}"
      {:ok, service_id} = Mdns.register_service(%{name: name, type: "_emptytxt._tcp", port: 8888, txt: %{}})

      service = Mdns.get_registered_service(service_id)
      assert service != nil
    end
  end
end
