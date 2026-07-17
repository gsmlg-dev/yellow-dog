defmodule YellowDog.Server.Control.Dhcpv4Test do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control.Dhcpv4
  alias YellowDog.Server.Control.Revision
  alias YellowDog.ServerDhcpv4ControlFake
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @pool %{
    "family" => "ipv4",
    "pool_id" => "office",
    "subnet" => "192.0.2.0/24",
    "start_address" => "192.0.2.20",
    "end_address" => "192.0.2.100",
    "lease_seconds" => 3600
  }

  setup do
    previous = Application.get_env(:yellow_dog, Dhcpv4)

    Application.put_env(:yellow_dog, Dhcpv4,
      pool_store: ServerDhcpv4ControlFake.PoolStore,
      lease_manager: ServerDhcpv4ControlFake.LeaseManager,
      clock: ServerDhcpv4ControlFake.Clock
    )

    start_supervised!(ServerDhcpv4ControlFake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:yellow_dog, Dhcpv4, previous),
        else: Application.delete_env(:yellow_dog, Dhcpv4)
    end)

    :ok
  end

  test "projects canonical persisted pools with a stable bounded result" do
    ServerDhcpv4ControlFake.configure(%{
      pools: [
        pool_config(@pool),
        pool_config(%{
          @pool
          | "pool_id" => "lab",
            "start_address" => "192.0.2.110",
            "end_address" => "192.0.2.120"
        })
      ]
    })

    assert {:ok, result} =
             Dhcpv4.dispatch("server.dhcp.pools.list", %{"family" => "ipv4", "limit" => 1})

    expected =
      Map.merge(@pool, %{
        "pool_id" => "lab",
        "start_address" => "192.0.2.110",
        "end_address" => "192.0.2.120"
      })

    assert [^expected] = result["items"]

    assert result["observed_at"] == "2026-07-17T00:00:00Z"
    assert_valid_result("server.dhcp.pools.list", result)

    assert [{:pool_store, :control_snapshot, []}, {:clock, :utc_now, []}] =
             ServerDhcpv4ControlFake.take_calls()
  end

  test "projects opaque leases and runtime status" do
    lease = %{lease_id: "lease-001122334455", address: "192.0.2.20", state: :active}
    ServerDhcpv4ControlFake.configure(%{leases: [lease], status: :failed})

    assert {:ok, leases} = Dhcpv4.dispatch("server.dhcp.leases.list", %{"family" => "ipv4"})

    assert leases["items"] == [
             %{
               "family" => "ipv4",
               "lease_id" => "lease-001122334455",
               "address" => "192.0.2.20",
               "state" => "active"
             }
           ]

    assert_valid_result("server.dhcp.leases.list", leases)

    assert {:ok, %{"family" => "ipv4", "status" => "failed"} = status} =
             Dhcpv4.dispatch("server.dhcp.status.get", %{"family" => "ipv4"})

    assert_valid_result("server.dhcp.status.get", status)
  end

  test "rejects non-ipv4 payloads and keeps unsupported activity side-effect free" do
    assert {:error, %Error{code: :invalid}} =
             Dhcpv4.dispatch("server.dhcp.status.get", %{"family" => "ipv6"})

    assert [] = ServerDhcpv4ControlFake.take_calls()

    assert {:error, %Error{code: :unsupported}} =
             Dhcpv4.dispatch("server.dhcp.activity.list", %{"family" => "ipv4"})

    assert [] = ServerDhcpv4ControlFake.take_calls()
  end

  test "rejects malformed pool payloads before owner calls" do
    invalid = %{@pool | "subnet" => "192.0.2.0/24", "start_address" => "2001:db8::1"}

    assert {:error, %Error{code: :invalid}} = Dhcpv4.dispatch("server.dhcp.pools.create", invalid)
    assert [] = ServerDhcpv4ControlFake.take_calls()
  end

  test "creates a validated pool by persisting before activating the manager" do
    config = pool_config(@pool)

    assert {:ok, result} = Dhcpv4.dispatch("server.dhcp.pools.create", @pool)
    assert result["resource_type"] == "dhcp_pool"
    assert result["resource_id"] == "office"
    assert result["resource"] == @pool
    assert_valid_result("server.dhcp.pools.create", result)

    assert [
             {:pool_store, :control_snapshot, []},
             {:lease_manager, :control_pool_snapshot, []},
             {:pool_store, :control_validate_pool, [^config]},
             {:pool_store, :control_persist_snapshot, [[^config]]},
             {:lease_manager, :control_apply_pool_snapshot, [[^config]]}
           ] = ServerDhcpv4ControlFake.take_calls()
  end

  test "exposes projected current resources for revision checks" do
    ServerDhcpv4ControlFake.configure(%{
      pools: [pool_config(@pool)],
      leases: [%{lease_id: "lease-001122334455", address: "192.0.2.20", state: :active}]
    })

    assert {:ok, current_pool} = Dhcpv4.current("server.dhcp.pools.update", @pool)
    assert current_pool == @pool

    assert {:ok, current_lease} =
             Dhcpv4.current("server.dhcp.leases.release", %{
               "family" => "ipv4",
               "lease_id" => "lease-001122334455"
             })

    assert current_lease["address"] == "192.0.2.20"
    assert {:ok, revision} = Revision.calculate(current_pool)
    assert byte_size(revision) == 64
  end

  test "normal delete rejects active leases while force delete preserves them" do
    ServerDhcpv4ControlFake.configure(%{
      pools: [pool_config(@pool)],
      runtime_pools: [pool_config(@pool)],
      active_pools: MapSet.new(["office"]),
      leases: [%{lease_id: "lease-001122334455", address: "192.0.2.20", state: :active}]
    })

    assert {:error, %Error{code: :conflict}} =
             Dhcpv4.dispatch("server.dhcp.pools.delete", %{
               "family" => "ipv4",
               "pool_id" => "office"
             })

    refute Enum.any?(
             ServerDhcpv4ControlFake.take_calls(),
             &match?({:pool_store, :control_persist_snapshot, _}, &1)
           )

    assert {:ok, result} =
             Dhcpv4.dispatch("server.dhcp.pools.force_delete", %{
               "family" => "ipv4",
               "pool_id" => "office",
               "force" => true
             })

    assert result["resource_ref"] == %{"family" => "ipv4", "pool_id" => "office"}
    assert_valid_result("server.dhcp.pools.force_delete", result)
    assert [%{lease_id: "lease-001122334455"}] = ServerDhcpv4ControlFake.snapshot().leases
  end

  test "does not activate or roll back after initial persistence failure" do
    ServerDhcpv4ControlFake.configure(%{responses: %{persist: [{:error, :disk_full}]}})

    assert {:error, %Error{code: :apply_failed}} =
             Dhcpv4.dispatch("server.dhcp.pools.create", @pool)

    calls = ServerDhcpv4ControlFake.take_calls()
    refute Enum.any?(calls, &match?({:lease_manager, :control_apply_pool_snapshot, _}, &1))
    assert Enum.count(calls, &match?({:pool_store, :control_persist_snapshot, _}, &1)) == 1
  end

  test "reports apply failure after a complete rollback and rollback failure otherwise" do
    ServerDhcpv4ControlFake.configure(%{responses: %{apply: [{:error, :bad_runtime}, :ok]}})

    assert {:error, %Error{code: :apply_failed}} =
             Dhcpv4.dispatch("server.dhcp.pools.create", @pool)

    ServerDhcpv4ControlFake.configure(%{
      responses: %{apply: [{:error, :bad_runtime}], persist: [:ok, {:error, :restore_failed}]}
    })

    assert {:error, %Error{code: :rollback_failed}} =
             Dhcpv4.dispatch("server.dhcp.pools.create", @pool)
  end

  test "maps absent managers and releases leases with the exact result" do
    ServerDhcpv4ControlFake.configure(%{responses: %{status: [{:error, :manager_absent}]}})

    assert {:error, %Error{code: :not_found}} =
             Dhcpv4.dispatch("server.dhcp.status.get", %{"family" => "ipv4"})

    ServerDhcpv4ControlFake.configure(%{
      leases: [%{lease_id: "lease-001122334455", address: "192.0.2.20", state: :active}]
    })

    assert {:ok, result} =
             Dhcpv4.dispatch("server.dhcp.leases.release", %{
               "family" => "ipv4",
               "lease_id" => "lease-001122334455"
             })

    assert result == %{
             "family" => "ipv4",
             "lease_id" => "lease-001122334455",
             "address" => "192.0.2.20",
             "released" => true
           }

    assert_valid_result("server.dhcp.leases.release", result)
  end

  defp pool_config(resource) do
    %{
      name: resource["pool_id"],
      network: resource["subnet"],
      range_start: resource["start_address"],
      range_end: resource["end_address"],
      subnet_mask: "255.255.255.0",
      lease_time: resource["lease_seconds"]
    }
  end

  defp assert_valid_result(operation_name, result) do
    assert {:ok, operation} = ServerOperation.fetch(operation_name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end
end
