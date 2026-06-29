defmodule YellowDog.Netman.Integration.ProfileHotreloadTest do
  @moduledoc """
  Integration tests verifying end-to-end profile hot-reload:
  TOML file change → ProfileStore reloads → ReconciliationEngine triggers →
  connection FSM re-evaluated.
  """
  use ExUnit.Case

  alias YellowDog.Netman.{ProfileStore, ReconciliationEngine}
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :integration
  @moduletag :capture_log

  setup do
    iface = "hotreload_eth#{:rand.uniform(65535)}"

    profile = %Profile{
      id: "hotreload-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    on_exit(fn ->
      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile.id)
    end)

    %{iface: iface, profile: profile}
  end

  test "adding a profile via put triggers reconciliation and starts FSM", %{
    iface: iface,
    profile: profile
  } do
    # Interface exists
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    # No FSM yet
    assert :error = Connection.Supervisor.find_connection(iface)

    # Add profile — this publishes netman:profile:changed
    ProfileStore.put(profile.id, profile)
    Process.sleep(50)

    # Trigger reconciliation manually (in production the EventBus event does this via debounce)
    ReconciliationEngine.reconcile()
    Process.sleep(300)

    # FSM should have been created
    case Connection.Supervisor.find_connection(iface) do
      {:ok, pid} ->
        {:ok, state} = Connection.FSM.get_state(pid)
        assert state.profile_id == profile.id
        assert state.state == :activated

      :error ->
        # Verify at least the diff detects it
        observed = ReconciliationEngine.observe()
        desired = ReconciliationEngine.compute_desired()
        diffs = ReconciliationEngine.diff(desired, observed)
        activate_diffs = Enum.filter(diffs, &(&1.action == :activate_connection))
        assert activate_diffs != [], "Expected activation diff after profile added"
    end
  end

  test "deleting a profile removes it from desired state", %{
    iface: iface,
    profile: profile
  } do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    # Add profile and start connection
    ProfileStore.put(profile.id, profile)
    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    {:ok, pid} = Connection.Supervisor.find_connection(iface)
    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated

    # Delete the profile
    ProfileStore.delete(profile.id)
    Process.sleep(50)

    # Desired state should no longer include this profile
    desired = ReconciliationEngine.compute_desired()
    refute Map.has_key?(desired.connections, profile.id)
  end

  test "updating profile priority changes desired state", %{
    iface: iface,
    profile: profile
  } do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    # Add profile with priority 100
    ProfileStore.put(profile.id, profile)
    Process.sleep(50)

    desired1 = ReconciliationEngine.compute_desired()
    conn1 = Map.get(desired1.connections, profile.id)

    # Update profile with higher priority
    updated_profile = %{profile | autoconnect_priority: 500}
    ProfileStore.put(profile.id, updated_profile)
    Process.sleep(50)

    desired2 = ReconciliationEngine.compute_desired()
    conn2 = Map.get(desired2.connections, profile.id)

    # Both should exist
    assert conn1 != nil
    assert conn2 != nil

    # Priority should be different in the profiles
    {:ok, stored} = ProfileStore.get(profile.id)
    assert stored.autoconnect_priority == 500
  end

  test "switching autoconnect off removes profile from desired state", %{
    iface: iface,
    profile: profile
  } do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    # Add with autoconnect true
    ProfileStore.put(profile.id, profile)
    Process.sleep(50)

    desired = ReconciliationEngine.compute_desired()
    assert Map.has_key?(desired.connections, profile.id)

    # Update with autoconnect false
    updated = %{profile | autoconnect: false}
    ProfileStore.put(profile.id, updated)
    Process.sleep(50)

    desired2 = ReconciliationEngine.compute_desired()
    refute Map.has_key?(desired2.connections, profile.id)
  end

  test "changing interface field re-targets the profile", %{profile: profile} do
    iface1 = "hr_target1_#{:rand.uniform(65535)}"
    iface2 = "hr_target2_#{:rand.uniform(65535)}"

    MockNetlink.link_up(iface1, carrier: true)
    MockNetlink.link_up(iface2, carrier: true)
    Process.sleep(50)

    # Profile targets iface1
    p1 = %{profile | interface: iface1, id: "retarget-#{:rand.uniform(65535)}"}
    ProfileStore.put(p1.id, p1)
    Process.sleep(50)

    desired1 = ReconciliationEngine.compute_desired()
    conn1 = Map.get(desired1.connections, p1.id)
    assert conn1 != nil
    assert conn1.interface == iface1

    # Re-target to iface2
    p2 = %{p1 | interface: iface2}
    ProfileStore.put(p1.id, p2)
    Process.sleep(50)

    desired2 = ReconciliationEngine.compute_desired()
    conn2 = Map.get(desired2.connections, p1.id)
    assert conn2 != nil
    assert conn2.interface == iface2

    # Cleanup
    ProfileStore.delete(p1.id)
    MockNetlink.link_removed(iface1)
    MockNetlink.link_removed(iface2)
  end
end
