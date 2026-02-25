defmodule YellowDog.ServiceManagerTest do
  @moduledoc """
  Tests for YellowDog.ServiceManager.

  Tests the service management API. Since Config and the protocol
  supervisors may not be running in all test environments, we
  focus on the pure functions and error paths.
  """
  use ExUnit.Case, async: true

  alias YellowDog.ServiceManager

  # ── Module structure ──────────────────────────────────────────────

  describe "module structure" do
    test "module is loadable" do
      assert {:module, ServiceManager} = Code.ensure_loaded(ServiceManager)
    end

    test "exports get_all_status/0" do
      Code.ensure_loaded!(ServiceManager)
      assert function_exported?(ServiceManager, :get_all_status, 0)
    end

    test "exports get_service_status/1" do
      Code.ensure_loaded!(ServiceManager)
      assert function_exported?(ServiceManager, :get_service_status, 1)
    end

    test "exports list_services/0" do
      Code.ensure_loaded!(ServiceManager)
      assert function_exported?(ServiceManager, :list_services, 0)
    end

    test "exports get_service_stats/1" do
      Code.ensure_loaded!(ServiceManager)
      assert function_exported?(ServiceManager, :get_service_stats, 1)
    end

    test "exports format_status/1" do
      Code.ensure_loaded!(ServiceManager)
      assert function_exported?(ServiceManager, :format_status, 1)
    end

    test "exports start_service/1" do
      Code.ensure_loaded!(ServiceManager)
      assert function_exported?(ServiceManager, :start_service, 1)
    end

    test "exports stop_service/1" do
      Code.ensure_loaded!(ServiceManager)
      assert function_exported?(ServiceManager, :stop_service, 1)
    end
  end

  # ── list_services/0 ───────────────────────────────────────────────

  describe "list_services/0" do
    test "returns the four protocol services" do
      services = ServiceManager.list_services()
      assert is_list(services)
      assert :dns in services
      assert :mdns in services
      assert :dhcpv4 in services
      assert :dhcpv6 in services
    end

    test "returns exactly 4 services" do
      assert length(ServiceManager.list_services()) == 4
    end
  end

  # ── get_service_status/1 for unknown service ──────────────────────

  describe "get_service_status/1 error handling" do
    test "returns error for unknown service" do
      status = ServiceManager.get_service_status(:nonexistent)
      assert status == %{error: "Unknown service"}
    end

    test "returns error for nil service" do
      status = ServiceManager.get_service_status(nil)
      assert status == %{error: "Unknown service"}
    end
  end

  # ── get_service_stats/1 ──────────────────────────────────────────

  describe "get_service_stats/1" do
    test "returns error map for unknown service" do
      assert %{error: "Unknown service"} = ServiceManager.get_service_stats(:bogus)
    end
  end

  # ── start_service/1 error handling ───────────────────────────────

  describe "start_service/1 error handling" do
    test "returns error for unknown service" do
      assert {:error, :unknown_service} = ServiceManager.start_service(:nonexistent)
    end
  end

  # ── stop_service/1 error handling ────────────────────────────────

  describe "stop_service/1 error handling" do
    test "returns error for unknown service" do
      assert {:error, :unknown_service} = ServiceManager.stop_service(:nonexistent)
    end
  end

  # ── format_status/1 ──────────────────────────────────────────────

  describe "format_status/1" do
    test "returns string for unknown service" do
      assert ServiceManager.format_status(:nonexistent) == "Unknown service"
    end
  end
end
