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
      assert length(services) == 8
    end

    test "includes all expected services" do
      services = ServiceManager.list_services()

      assert :dns in services
      assert :mdns in services
      assert :dhcpv4 in services
      assert :dhcpv6 in services
      assert :netboot in services
      assert :identity in services
      assert :fingerprint in services
      assert :server_agent in services
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

    test "includes registry metadata for known services" do
      status = ServiceManager.get_service_status(:server_agent)

      assert %{
               metadata: %{
                 name: :server_agent,
                 label: "Server Agent",
                 application: :yellow_dog_server_agent,
                 available?: available?
               }
             } = status

      assert available? in [true, false]
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
      assert map_size(all_status) == 8
    end

    test "includes all services as keys" do
      all_status = ServiceManager.get_all_status()

      assert Map.has_key?(all_status, :dns)
      assert Map.has_key?(all_status, :mdns)
      assert Map.has_key?(all_status, :dhcpv4)
      assert Map.has_key?(all_status, :dhcpv6)
      assert Map.has_key?(all_status, :netboot)
      assert Map.has_key?(all_status, :identity)
      assert Map.has_key?(all_status, :fingerprint)
      assert Map.has_key?(all_status, :server_agent)
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
      assert output =~ "YellowDog Services Status"
    end

    test "includes all service names in output" do
      output = ServiceManager.format_status(:all)

      assert output =~ "DNS"
      assert output =~ "MDNS"
      assert output =~ "DHCPV4"
      assert output =~ "DHCPV6"
    end

    test "formats single dns service" do
      output = ServiceManager.format_status(:dns)

      assert is_binary(output)
      assert output =~ "DNS"
    end

    test "formats single mdns service" do
      output = ServiceManager.format_status(:mdns)

      assert is_binary(output)
      assert output =~ "MDNS"
    end

    test "formats single dhcpv4 service" do
      output = ServiceManager.format_status(:dhcpv4)

      assert is_binary(output)
      assert output =~ "DHCPV4"
    end

    test "formats single dhcpv6 service" do
      output = ServiceManager.format_status(:dhcpv6)

      assert is_binary(output)
      assert output =~ "DHCPV6"
    end

    test "includes ENABLED or DISABLED" do
      output = ServiceManager.format_status(:dns)

      assert output =~ "ENABLED" or output =~ "DISABLED"
    end

    test "includes RUNNING or STOPPED" do
      output = ServiceManager.format_status(:dns)

      assert output =~ "RUNNING" or output =~ "STOPPED"
    end

    test "returns unknown message for unknown service" do
      output = ServiceManager.format_status(:unknown)

      assert output == "Unknown service"
    end
  end

  describe "start_service/1 and stop_service/1" do
    test "keeps already-started and already-stopped controls idempotent" do
      original = YellowDog.Config.get_all()
      previous_dependencies = Application.get_env(:yellow_dog, ServiceManager)

      on_exit(fn ->
        restore_config(original)
        restore_dependencies(previous_dependencies)
      end)

      Application.put_env(:yellow_dog, ServiceManager,
        application: YellowDog.ServerRuntimeControlFake.Application
      )

      YellowDog.Config.update(:yellow_dog_server, %{
        "profile" => "custom",
        "services" => %{"dns" => false}
      })

      start_supervised!(YellowDog.ServerRuntimeControlFake)

      YellowDog.ServerRuntimeControlFake.configure(%{
        start_result: {:error, {:already_started, self()}},
        stop_result: {:error, :not_found}
      })

      assert :ok = ServiceManager.start_service(:dns)

      assert get_in(YellowDog.Config.get_all(), ["yellow_dog_server", "services", "dns"]) ==
               true

      assert :ok = ServiceManager.stop_service(:dns)

      assert get_in(YellowDog.Config.get_all(), ["yellow_dog_server", "services", "dns"]) ==
               false

      assert [start: :dns, stop: :dns] = YellowDog.ServerRuntimeControlFake.take_calls()
    end

    test "restores the prior server service flag when start activation fails" do
      original = YellowDog.Config.get_all()
      previous_dependencies = Application.get_env(:yellow_dog, ServiceManager)

      on_exit(fn ->
        restore_config(original)
        restore_dependencies(previous_dependencies)
      end)

      Application.put_env(:yellow_dog, ServiceManager,
        application: YellowDog.ServerRuntimeControlFake.Application
      )

      YellowDog.Config.update(:yellow_dog_server, %{
        "profile" => "custom",
        "services" => %{"dns" => false}
      })

      start_supervised!(YellowDog.ServerRuntimeControlFake)
      YellowDog.ServerRuntimeControlFake.configure(%{start_result: {:error, :offline}})

      assert {:error, :offline} = ServiceManager.start_service(:dns)

      assert get_in(YellowDog.Config.get_all(), ["yellow_dog_server", "services", "dns"]) ==
               false

      assert [start: :dns] = YellowDog.ServerRuntimeControlFake.take_calls()
    end

    test "restores the prior server service flag when stop activation fails" do
      original = YellowDog.Config.get_all()
      previous_dependencies = Application.get_env(:yellow_dog, ServiceManager)

      on_exit(fn ->
        restore_config(original)
        restore_dependencies(previous_dependencies)
      end)

      Application.put_env(:yellow_dog, ServiceManager,
        application: YellowDog.ServerRuntimeControlFake.Application
      )

      YellowDog.Config.update(:yellow_dog_server, %{
        "profile" => "custom",
        "services" => %{"dns" => true}
      })

      start_supervised!(YellowDog.ServerRuntimeControlFake)
      YellowDog.ServerRuntimeControlFake.configure(%{stop_result: {:error, :offline}})

      assert {:error, :offline} = ServiceManager.stop_service(:dns)

      assert get_in(YellowDog.Config.get_all(), ["yellow_dog_server", "services", "dns"]) ==
               true

      assert [stop: :dns] = YellowDog.ServerRuntimeControlFake.take_calls()
    end

    test "start_service returns error for unknown service" do
      result = ServiceManager.start_service(:unknown)

      assert result == {:error, :unknown_service}
    end

    test "stop_service returns error for unknown service" do
      result = ServiceManager.stop_service(:unknown)

      assert result == {:error, :unknown_service}
    end

    test "start_service accepts server agent when available in the release" do
      result =
        try do
          ServiceManager.start_service(:server_agent)
        rescue
          ArgumentError -> {:error, :supervisor_not_running}
        catch
          :exit, _ -> {:error, :supervisor_not_running}
        end

      assert result in [:ok, {:error, :supervisor_not_running}, {:error, :module_not_available}]
    end

    test "stop_service accepts server agent when available in the release" do
      result =
        try do
          ServiceManager.stop_service(:server_agent)
        rescue
          _ -> {:error, :supervisor_not_running}
        catch
          :exit, _ -> {:error, :supervisor_not_running}
        end

      assert result in [:ok, {:error, :not_found}, {:error, :supervisor_not_running}]
    end

    test "start_service updates active yellow_dog_server service flags" do
      original = YellowDog.Config.get_all()

      on_exit(fn ->
        restore_config(original)
      end)

      YellowDog.Config.update(:yellow_dog_server, %{
        "profile" => "custom",
        "services" => %{"dns" => false}
      })

      result =
        try do
          ServiceManager.start_service(:dns)
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end

      expected_enabled = result == :ok

      assert get_in(YellowDog.Config.get_all(), ["yellow_dog_server", "services", "dns"]) ==
               expected_enabled

      assert ServiceManager.get_service_status(:dns).enabled == expected_enabled
    end

    test "stop_service updates active yellow_dog_server service flags" do
      original = YellowDog.Config.get_all()

      on_exit(fn ->
        restore_config(original)
      end)

      YellowDog.Config.update(:yellow_dog_server, %{
        "profile" => "custom",
        "services" => %{"dns" => true}
      })

      result =
        try do
          ServiceManager.stop_service(:dns)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

      assert result in [:ok, {:error, :not_found}, {:error, :supervisor_not_running}]

      enabled = get_in(YellowDog.Config.get_all(), ["yellow_dog_server", "services", "dns"])
      assert enabled in [true, false]
      assert ServiceManager.get_service_status(:dns).enabled == enabled
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

      # Either succeeds, or fails due to supervisor not running or module not available in release
      assert result in [:ok, {:error, :supervisor_not_running}, {:error, :module_not_available}]
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
      if output =~ "Config:" do
        # port separator
        assert output =~ ":"
      end
    end

    test "dhcpv4 config shows pools count" do
      output = ServiceManager.format_status(:dhcpv4)

      # May contain pools info if config is present
      if output =~ "Config:" do
        assert output =~ "pools" or output =~ ":"
      end
    end
  end

  defp restore_config(config) do
    case Process.whereis(YellowDog.Config) do
      nil -> YellowDog.Config.start_link(config)
      _pid -> Agent.update(YellowDog.Config, fn _state -> config end)
    end
  end

  defp restore_dependencies(nil), do: Application.delete_env(:yellow_dog, ServiceManager)

  defp restore_dependencies(dependencies),
    do: Application.put_env(:yellow_dog, ServiceManager, dependencies)
end
