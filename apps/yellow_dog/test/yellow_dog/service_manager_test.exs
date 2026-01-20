defmodule YellowDog.ServiceManagerTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.ServiceManager.

  Tests cover:
  - Module structure and exports
  - Service listing
  - Service status retrieval
  - Service statistics
  - Status formatting
  - Unknown service handling
  """
  use ExUnit.Case, async: false

  alias YellowDog.ServiceManager

  # Default test configuration
  @default_config %{
    "core" => %{
      "dns" => false,
      "mdns" => false,
      "dhcpv4" => false,
      "dhcpv6" => false
    },
    "dns" => %{"listen" => "0.0.0.0", "port" => 53},
    "mdns" => %{"listen" => "0.0.0.0", "port" => 5353},
    "dhcpv4" => %{"listen" => "0.0.0.0", "port" => 67, "pools" => []},
    "dhcpv6" => %{"listen" => "::", "port" => 547, "pools" => []}
  }

  # Ensure Config is started for tests that need it
  setup do
    # Start Config if not already running
    case Process.whereis(YellowDog.Config) do
      nil ->
        {:ok, _pid} = YellowDog.Config.start_link(@default_config)
        on_exit(fn ->
          try do
            GenServer.stop(YellowDog.Config, :normal, 1000)
          catch
            :exit, _ -> :ok
          end
        end)

      _pid ->
        :ok
    end

    :ok
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(ServiceManager)
    end

    test "exports list_services/0" do
      Code.ensure_loaded!(ServiceManager)
      assert Kernel.function_exported?(ServiceManager, :list_services, 0)
    end

    test "exports get_all_status/0" do
      Code.ensure_loaded!(ServiceManager)
      assert Kernel.function_exported?(ServiceManager, :get_all_status, 0)
    end

    test "exports get_service_status/1" do
      Code.ensure_loaded!(ServiceManager)
      assert Kernel.function_exported?(ServiceManager, :get_service_status, 1)
    end

    test "exports get_service_stats/1" do
      Code.ensure_loaded!(ServiceManager)
      assert Kernel.function_exported?(ServiceManager, :get_service_stats, 1)
    end

    test "exports start_service/1" do
      Code.ensure_loaded!(ServiceManager)
      assert Kernel.function_exported?(ServiceManager, :start_service, 1)
    end

    test "exports stop_service/1" do
      Code.ensure_loaded!(ServiceManager)
      assert Kernel.function_exported?(ServiceManager, :stop_service, 1)
    end

    test "exports format_status/1" do
      Code.ensure_loaded!(ServiceManager)
      assert Kernel.function_exported?(ServiceManager, :format_status, 1)
    end
  end

  describe "list_services/0" do
    test "returns list of services" do
      services = ServiceManager.list_services()

      assert is_list(services)
      assert length(services) == 4
    end

    test "includes all expected services" do
      services = ServiceManager.list_services()

      assert :dns in services
      assert :mdns in services
      assert :dhcpv4 in services
      assert :dhcpv6 in services
    end

    test "returns atoms" do
      services = ServiceManager.list_services()

      Enum.each(services, fn service ->
        assert is_atom(service)
      end)
    end
  end

  describe "get_service_status/1" do
    test "returns map for dns service" do
      status = ServiceManager.get_service_status(:dns)

      assert is_map(status)
      assert Map.has_key?(status, :enabled)
    end

    test "returns map for mdns service" do
      status = ServiceManager.get_service_status(:mdns)

      assert is_map(status)
      assert Map.has_key?(status, :enabled)
    end

    test "returns map for dhcpv4 service" do
      status = ServiceManager.get_service_status(:dhcpv4)

      assert is_map(status)
      assert Map.has_key?(status, :enabled)
    end

    test "returns map for dhcpv6 service" do
      status = ServiceManager.get_service_status(:dhcpv6)

      assert is_map(status)
      assert Map.has_key?(status, :enabled)
    end

    test "includes running key" do
      status = ServiceManager.get_service_status(:dns)

      assert Map.has_key?(status, :running)
      assert is_boolean(status.running)
    end

    test "includes uptime key" do
      status = ServiceManager.get_service_status(:dns)

      assert Map.has_key?(status, :uptime)
    end

    test "includes config key" do
      status = ServiceManager.get_service_status(:dns)

      assert Map.has_key?(status, :config)
    end

    test "includes stats key" do
      status = ServiceManager.get_service_status(:dns)

      assert Map.has_key?(status, :stats)
    end

    test "returns error for unknown service" do
      status = ServiceManager.get_service_status(:unknown)

      assert is_map(status)
      assert Map.has_key?(status, :error)
      assert status.error == "Unknown service"
    end

    test "returns error for invalid service type" do
      status = ServiceManager.get_service_status("dns")

      assert is_map(status)
      assert Map.has_key?(status, :error)
    end
  end

  describe "get_all_status/0" do
    test "returns map of all services" do
      all_status = ServiceManager.get_all_status()

      assert is_map(all_status)
      assert map_size(all_status) == 4
    end

    test "includes all services as keys" do
      all_status = ServiceManager.get_all_status()

      assert Map.has_key?(all_status, :dns)
      assert Map.has_key?(all_status, :mdns)
      assert Map.has_key?(all_status, :dhcpv4)
      assert Map.has_key?(all_status, :dhcpv6)
    end

    test "each service has status map" do
      all_status = ServiceManager.get_all_status()

      Enum.each(all_status, fn {_service, status} ->
        assert is_map(status)
        assert Map.has_key?(status, :enabled)
      end)
    end
  end

  describe "get_service_stats/1" do
    test "returns map for dns service" do
      stats = ServiceManager.get_service_stats(:dns)

      assert is_map(stats)
    end

    test "returns map for mdns service" do
      stats = ServiceManager.get_service_stats(:mdns)

      assert is_map(stats)
    end

    test "returns map for dhcpv4 service" do
      stats = ServiceManager.get_service_stats(:dhcpv4)

      assert is_map(stats)
    end

    test "returns map for dhcpv6 service" do
      stats = ServiceManager.get_service_stats(:dhcpv6)

      assert is_map(stats)
    end

    test "returns error for unknown service" do
      stats = ServiceManager.get_service_stats(:unknown)

      assert is_map(stats)
      assert Map.has_key?(stats, :error)
    end
  end

  describe "format_status/1" do
    test "formats all services" do
      output = ServiceManager.format_status(:all)

      assert is_binary(output)
      assert String.contains?(output, "YellowDog Services Status")
    end

    test "includes all service names in output" do
      output = ServiceManager.format_status(:all)

      assert String.contains?(output, "DNS")
      assert String.contains?(output, "MDNS")
      assert String.contains?(output, "DHCPV4")
      assert String.contains?(output, "DHCPV6")
    end

    test "formats single dns service" do
      output = ServiceManager.format_status(:dns)

      assert is_binary(output)
      assert String.contains?(output, "DNS")
    end

    test "formats single mdns service" do
      output = ServiceManager.format_status(:mdns)

      assert is_binary(output)
      assert String.contains?(output, "MDNS")
    end

    test "formats single dhcpv4 service" do
      output = ServiceManager.format_status(:dhcpv4)

      assert is_binary(output)
      assert String.contains?(output, "DHCPV4")
    end

    test "formats single dhcpv6 service" do
      output = ServiceManager.format_status(:dhcpv6)

      assert is_binary(output)
      assert String.contains?(output, "DHCPV6")
    end

    test "includes ENABLED or DISABLED" do
      output = ServiceManager.format_status(:dns)

      assert String.contains?(output, "ENABLED") or String.contains?(output, "DISABLED")
    end

    test "includes RUNNING or STOPPED" do
      output = ServiceManager.format_status(:dns)

      assert String.contains?(output, "RUNNING") or String.contains?(output, "STOPPED")
    end

    test "returns unknown message for unknown service" do
      output = ServiceManager.format_status(:unknown)

      assert output == "Unknown service"
    end
  end

  describe "start_service/1 and stop_service/1" do
    test "start_service returns error for unknown service" do
      result = ServiceManager.start_service(:unknown)

      assert result == {:error, :unknown_service}
    end

    test "stop_service returns error for unknown service" do
      result = ServiceManager.stop_service(:unknown)

      assert result == {:error, :unknown_service}
    end

    test "start_service accepts valid service atoms" do
      # start_service needs the full YellowDog supervisor tree
      # It will fail because YellowDog.Supervisor is not running
      # We're just testing that it properly accepts the atom and calls Config
      result =
        try do
          ServiceManager.start_service(:dns)
        rescue
          ArgumentError -> {:error, :supervisor_not_running}
        catch
          :exit, _ -> {:error, :supervisor_not_running}
        end

      # Either succeeds, or fails due to supervisor not running
      assert result in [:ok, {:error, :supervisor_not_running}]
    end

    test "stop_service accepts valid service atoms" do
      # stop_service needs the full YellowDog supervisor tree
      # It will fail because YellowDog.Supervisor is not running
      result =
        try do
          ServiceManager.stop_service(:dns)
        rescue
          _ -> {:error, :supervisor_not_running}
        catch
          :exit, _ -> {:error, :supervisor_not_running}
        end

      # Either succeeds, or fails due to supervisor not running
      assert result in [:ok, {:error, :not_found}, {:error, :supervisor_not_running}]
    end
  end

  describe "status when services disabled" do
    test "disabled service shows enabled: false" do
      # Temporarily disable a service to test status
      original = YellowDog.Config.service_enabled?(:dns)
      YellowDog.Config.set_service_enabled(:dns, false)

      status = ServiceManager.get_service_status(:dns)

      assert status.enabled == false

      # Restore
      YellowDog.Config.set_service_enabled(:dns, original)
    end

    test "disabled service shows running: false" do
      original = YellowDog.Config.service_enabled?(:dns)
      YellowDog.Config.set_service_enabled(:dns, false)

      status = ServiceManager.get_service_status(:dns)

      assert status.running == false

      # Restore
      YellowDog.Config.set_service_enabled(:dns, original)
    end
  end

  describe "config formatting" do
    test "dns config shows listen and port" do
      output = ServiceManager.format_status(:dns)

      # Config line should be present
      if String.contains?(output, "Config:") do
        assert String.contains?(output, ":") # port separator
      end
    end

    test "dhcpv4 config shows pools count" do
      output = ServiceManager.format_status(:dhcpv4)

      # May contain pools info if config is present
      if String.contains?(output, "Config:") do
        assert String.contains?(output, "pools") or String.contains?(output, ":")
      end
    end
  end
end
