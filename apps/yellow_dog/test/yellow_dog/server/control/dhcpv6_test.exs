defmodule YellowDog.Server.Control.Dhcpv6Test do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv6ControlFake
  alias YellowDog.Server.Control.Dhcpv6
  alias YellowDog.Sync.Error

  @pool %{
    name: "office",
    network: "2001:0DB8:0:0::/64",
    range_start: "2001:0DB8:0:0::100",
    range_end: "2001:0DB8:0:0::1ff",
    preferred_lifetime: 3600,
    valid_lifetime: 3600
  }

  setup do
    start_supervised!(Dhcpv6ControlFake)

    previous = Application.get_env(:yellow_dog, Dhcpv6)

    Application.put_env(:yellow_dog, Dhcpv6,
      pool_store: YellowDog.Dhcpv6ControlFake.PoolStore,
      lease_manager: YellowDog.Dhcpv6ControlFake.LeaseManager
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:yellow_dog, Dhcpv6, previous),
        else: Application.delete_env(:yellow_dog, Dhcpv6)
    end)

    :ok
  end

  test "lists canonical IPv6 pools with an exact Sync result" do
    Dhcpv6ControlFake.configure(pools: [@pool])

    assert {:ok,
            %{
              "items" => [
                %{
                  "family" => "ipv6",
                  "pool_id" => "office",
                  "subnet" => "2001:db8::/64",
                  "start_address" => "2001:db8::100",
                  "end_address" => "2001:db8::1ff",
                  "lease_seconds" => 3600
                }
              ],
              "revision" => revision,
              "observed_at" => observed_at
            }} = Dhcpv6.dispatch("server.dhcp.pools.list", %{"family" => "ipv6"})

    assert byte_size(revision) == 64
    assert {:ok, _, _} = DateTime.from_iso8601(observed_at)
  end

  test "rejects persisted pools whose DHCPv6 lifetimes cannot be represented losslessly" do
    Dhcpv6ControlFake.configure(pools: [%{@pool | valid_lifetime: 7200}])

    assert {:error, %Error{code: :unsupported}} =
             Dhcpv6.dispatch("server.dhcp.pools.list", %{"family" => "ipv6"})
  end

  test "activity is unsupported without contacting an owner" do
    assert {:error, %Error{code: :unsupported}} =
             Dhcpv6.dispatch("server.dhcp.activity.list", %{"family" => "ipv6"})

    assert [] = Dhcpv6ControlFake.take_calls()
  end

  test "status reports stopped when the lease manager is absent" do
    Dhcpv6ControlFake.configure(status: {:error, :manager_absent})

    assert {:error, %Error{code: :not_found}} =
             Dhcpv6.dispatch("server.dhcp.status.get", %{"family" => "ipv6"})
  end

  test "releases an opaque IPv6 lease with the exact Sync result" do
    Dhcpv6ControlFake.configure(
      leases: [%{lease_id: "lease-client-1", address: "2001:0db8::100", state: :active}]
    )

    assert {:ok,
            %{
              "family" => "ipv6",
              "lease_id" => "lease-client-1",
              "address" => "2001:db8::100",
              "released" => true
            }} =
             Dhcpv6.dispatch("server.dhcp.leases.release", %{
               "family" => "ipv6",
               "lease_id" => "lease-client-1"
             })
  end

  test "current projects a canonical pool resource" do
    Dhcpv6ControlFake.configure(pools: [@pool])

    assert {:ok,
            %{
              "family" => "ipv6",
              "pool_id" => "office",
              "subnet" => "2001:db8::/64",
              "start_address" => "2001:db8::100",
              "end_address" => "2001:db8::1ff",
              "lease_seconds" => 3600
            }} =
             Dhcpv6.current("server.dhcp.pools.update", write_payload("office"))
  end

  test "normal delete guards active leases while force delete leaves them untouched" do
    Dhcpv6ControlFake.configure(
      pools: [@pool],
      leases: [%{lease_id: "lease-client-1", pool_name: "office", address: "2001:db8::100"}]
    )

    payload = %{"family" => "ipv6", "pool_id" => "office"}

    assert {:error, %Error{code: :conflict}} =
             Dhcpv6.dispatch("server.dhcp.pools.delete", payload)

    assert [
             {:pool_store, :control_snapshot, []},
             {:lease_manager, :control_pool_snapshot, []},
             {:lease_manager, :control_pool_has_active_leases?, ["office"]}
           ] =
             Dhcpv6ControlFake.take_calls()

    assert {:ok, %{"resource_type" => "dhcp_pool", "resource_id" => "office"}} =
             Dhcpv6.dispatch("server.dhcp.pools.force_delete", Map.put(payload, "force", true))

    assert calls = Dhcpv6ControlFake.take_calls()
    assert {:pool_store, :control_persist_snapshot, [[]]} in calls

    refute Enum.any?(calls, fn {owner, function, _arguments} ->
             owner == :lease_manager and function == :control_release_lease
           end)
  end

  test "persistence failure leaves the runtime untouched" do
    Dhcpv6ControlFake.configure(save_pool: {:error, :disk_full})

    assert {:error, %Error{code: :apply_failed}} =
             Dhcpv6.dispatch("server.dhcp.pools.create", write_payload("new"))

    assert calls = Dhcpv6ControlFake.take_calls()
    assert Enum.count(calls, &match?({:pool_store, :control_persist_snapshot, _}, &1)) == 1
    refute Enum.any?(calls, &match?({:lease_manager, :control_apply_pool_snapshot, _}, &1))
  end

  test "apply failure restores persistence and the runtime snapshot" do
    Dhcpv6ControlFake.configure(
      pools: [@pool],
      apply_pools: [{:error, :rejected}, :ok]
    )

    assert {:error, %Error{code: :apply_failed}} =
             Dhcpv6.dispatch("server.dhcp.pools.create", write_payload("new"))

    assert calls = Dhcpv6ControlFake.take_calls()
    assert Enum.count(calls, &match?({:pool_store, :control_persist_snapshot, _}, &1)) == 2
    assert Enum.count(calls, &match?({:lease_manager, :control_apply_pool_snapshot, _}, &1)) == 2
  end

  test "rollback failure is surfaced distinctly" do
    Dhcpv6ControlFake.configure(
      pools: [@pool],
      apply_pools: [{:error, :rejected}],
      save_pool: [:ok, {:error, :disk_full}]
    )

    assert {:error, %Error{code: :rollback_failed}} =
             Dhcpv6.dispatch("server.dhcp.pools.create", write_payload("new"))
  end

  defp write_payload(pool_id) do
    %{
      "family" => "ipv6",
      "pool_id" => pool_id,
      "subnet" => "2001:db8::/64",
      "start_address" => "2001:db8::100",
      "end_address" => "2001:db8::1ff",
      "lease_seconds" => 3600
    }
  end
end
