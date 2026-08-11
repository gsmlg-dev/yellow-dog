defmodule YellowDog.Server.ConfigReconcilerTest do
  use ExUnit.Case, async: true

  alias YellowDog.Server.ConfigReconciler

  @dependencies %{
    profile_resolver: __MODULE__.ProfileResolver,
    runtime: __MODULE__.Runtime,
    service_registry: __MODULE__.ServiceRegistry
  }

  test "starts a service that becomes enabled" do
    previous = config(%{dns: false})
    next = config(%{dns: true})

    assert :ok = ConfigReconciler.reconcile(previous, next, @dependencies)
    assert_received {:start, :dns, __MODULE__.DnsSupervisor}
    refute_received {:stop, _, _}
  end

  test "stops a service that becomes disabled" do
    previous = config(%{dns: true})
    next = config(%{dns: false})

    assert :ok = ConfigReconciler.reconcile(previous, next, @dependencies)
    assert_received {:stop, :dns, __MODULE__.DnsSupervisor}
    refute_received {:start, _, _}
  end

  test "restarts only an enabled service whose effective config changed" do
    previous =
      config(%{dns: true, mdns: true}, %{
        "dns" => %{"port" => 53},
        "mdns" => %{"port" => 5353}
      })

    next =
      config(%{dns: true, mdns: true}, %{
        "dns" => %{"port" => 8053},
        "mdns" => %{"port" => 5353}
      })

    assert :ok = ConfigReconciler.reconcile(previous, next, @dependencies)
    assert_received {:stop, :dns, __MODULE__.DnsSupervisor}
    assert_received {:start, :dns, __MODULE__.DnsSupervisor}
    refute_received {:stop, :mdns, _}
    refute_received {:start, :mdns, _}
  end

  test "does nothing when resolved flags and service configs are unchanged" do
    previous = config(%{dns: true}, %{"dns" => %{port: 53}})
    next = config(%{dns: true}, %{"dns" => %{"port" => 53}})

    assert :ok = ConfigReconciler.reconcile(previous, next, @dependencies)
    refute_received {:start, _, _}
    refute_received {:stop, _, _}
  end

  test "never reconciles the management server agent" do
    previous = config(%{server_agent: false})
    next = config(%{server_agent: true})

    assert :ok = ConfigReconciler.reconcile(previous, next, @dependencies)
    refute_received {:start, _, _}
    refute_received {:stop, _, _}
  end

  test "accepts idempotent start and stop results" do
    Process.put({__MODULE__.Runtime, :start, :dns}, {:error, {:already_started, self()}})
    Process.put({__MODULE__.Runtime, :stop, :mdns}, {:error, :not_found})

    previous = config(%{dns: false, mdns: true})
    next = config(%{dns: true, mdns: false})

    assert :ok = ConfigReconciler.reconcile(previous, next, @dependencies)
  end

  test "fails fast with a stable error that does not expose the runtime reason" do
    Process.put({__MODULE__.Runtime, :start, :dns}, {:raise, "management-token-secret"})

    previous = config(%{dns: false, mdns: false})
    next = config(%{dns: true, mdns: true})

    assert {:error, {:service_reconciliation_failed, :dns, :start}} =
             ConfigReconciler.reconcile(previous, next, @dependencies)

    refute_received {:start, :mdns, _}

    result = ConfigReconciler.reconcile(previous, next, @dependencies)
    refute inspect(result) =~ "management-token-secret"
  end

  test "reports the restart phase without exposing its runtime error" do
    Process.put({__MODULE__.Runtime, :start, :dns}, {:error, {:secret, "hidden"}})

    previous = config(%{dns: true}, %{"dns" => %{"port" => 53}})
    next = config(%{dns: true}, %{"dns" => %{"port" => 8053}})

    assert {:error, {:service_reconciliation_failed, :dns, :restart_start}} =
             ConfigReconciler.reconcile(previous, next, @dependencies)
  end

  defp config(services, service_config \\ %{}) do
    Map.put(service_config, "yellow_dog_server", %{
      "profile" => "custom",
      "services" =>
        Map.new(services, fn {service, enabled?} -> {to_string(service), enabled?} end)
    })
  end

  defmodule ProfileResolver do
    @moduledoc false

    def resolve(config), do: YellowDog.Server.ProfileResolver.resolve(config)
  end

  defmodule ServiceRegistry do
    @moduledoc false

    def all do
      [
        %{
          name: :dns,
          supervisor: YellowDog.Server.ConfigReconcilerTest.DnsSupervisor,
          controllable?: true
        },
        %{
          name: :mdns,
          supervisor: YellowDog.Server.ConfigReconcilerTest.MdnsSupervisor,
          controllable?: true
        },
        %{
          name: :server_agent,
          supervisor: YellowDog.Server.ConfigReconcilerTest.ServerAgentSupervisor,
          controllable?: true
        },
        %{
          name: :internal,
          supervisor: YellowDog.Server.ConfigReconcilerTest.InternalSupervisor,
          controllable?: false
        }
      ]
    end
  end

  defmodule Runtime do
    @moduledoc false

    def start_service_supervisor(service, supervisor) do
      send(self(), {:start, service, supervisor})
      run(Process.get({__MODULE__, :start, service}, {:ok, self()}))
    end

    def stop_service_supervisor(service, supervisor) do
      send(self(), {:stop, service, supervisor})
      run(Process.get({__MODULE__, :stop, service}, :ok))
    end

    defp run({:raise, message}), do: raise(message)
    defp run(result), do: result
  end
end
