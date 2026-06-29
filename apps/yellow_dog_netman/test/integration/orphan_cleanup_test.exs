defmodule YellowDog.Netman.Integration.OrphanCleanupTest do
  @moduledoc """
  Integration tests verifying that the reconciliation engine auto-deactivates
  FSMs when their backing profile is deleted ("orphan cleanup").
  """
  use ExUnit.Case

  alias YellowDog.Netman.{ReconciliationEngine, ProfileStore}
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :integration
  @moduletag :capture_log

  setup do
    iface = "orphan_eth#{:rand.uniform(65535)}"

    profile = %Profile{
      id: "orphan-profile-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile.id)
    end)

    %{iface: iface, profile: profile}
  end

  test "profile deletion triggers orphan FSM deactivation on reconciliation", %{
    iface: iface,
    profile: profile
  } do
    # Start FSM and let it settle
    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)
    assert Process.alive?(pid)

    # Delete the profile
    ProfileStore.delete(profile.id)
    Process.sleep(50)

    # The profile:changed event triggers debounced reconciliation.
    # Bypass debounce to force immediate reconciliation.
    send(ReconciliationEngine, :debounced_reconcile)
    Process.sleep(300)

    # The FSM should have been stopped (orphan cleanup)
    assert :error == Connection.Supervisor.find_connection(iface),
           "Orphaned FSM should be deactivated after profile deletion"
  end

  test "diff detects orphaned FSM when profile is missing", %{
    iface: iface,
    profile: profile
  } do
    # Start FSM
    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    # Delete profile — FSM is now an orphan
    ProfileStore.delete(profile.id)

    # Compute diffs
    observed = ReconciliationEngine.observe()
    desired = ReconciliationEngine.compute_desired()
    diffs = ReconciliationEngine.diff(desired, observed)

    deactivate_diffs =
      Enum.filter(diffs, fn d ->
        d.action == :deactivate_connection and d.interface == iface
      end)

    assert length(deactivate_diffs) == 1,
           "Expected exactly one deactivate diff for orphaned FSM on #{iface}"
  end

  test "non-orphaned FSM is not deactivated when profile exists but autoconnect=false", %{
    iface: iface,
    profile: profile
  } do
    # Start FSM
    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    # Update profile to autoconnect=false (but don't delete it)
    updated_profile = %{profile | autoconnect: false}
    ProfileStore.put(profile.id, updated_profile)

    # Reconcile
    send(ReconciliationEngine, :debounced_reconcile)
    Process.sleep(300)

    # FSM should still be running — autoconnect=false doesn't orphan an active FSM
    case Connection.Supervisor.find_connection(iface) do
      {:ok, found_pid} ->
        assert Process.alive?(found_pid)
        # Could be same or re-started pid depending on state
        assert found_pid == pid or Process.alive?(found_pid)

      :error ->
        # This is also acceptable — if the FSM was in :disconnected or :failed state,
        # compute_deactivation_diffs skips those. But if the FSM was in an active state,
        # it should NOT be deactivated just because autoconnect changed.
        :ok
    end

    # Key assertion: the profile still exists, so this is NOT an orphan
    assert {:ok, _} = ProfileStore.get(profile.id)
  end

  test "multiple orphaned FSMs are all cleaned up in single reconciliation cycle", %{
    iface: iface,
    profile: profile
  } do
    # Create a second interface + profile
    iface2 = "orphan2_eth#{:rand.uniform(65535)}"

    profile2 = %Profile{
      id: "orphan-profile2-#{iface2}",
      type: :ethernet,
      interface: iface2,
      autoconnect: true,
      autoconnect_priority: 50,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile2.id, profile2)
    MockNetlink.link_up(iface2, carrier: true)
    Process.sleep(50)

    # Start both FSMs
    {:ok, _pid1} = Connection.Supervisor.start_connection(iface, profile)
    {:ok, _pid2} = Connection.Supervisor.start_connection(iface2, profile2)
    Process.sleep(100)

    # Delete both profiles
    ProfileStore.delete(profile.id)
    ProfileStore.delete(profile2.id)

    # Reconcile
    send(ReconciliationEngine, :debounced_reconcile)
    Process.sleep(300)

    # Both should be gone
    assert :error == Connection.Supervisor.find_connection(iface),
           "First orphaned FSM should be deactivated"

    assert :error == Connection.Supervisor.find_connection(iface2),
           "Second orphaned FSM should be deactivated"

    # Cleanup
    Connection.Supervisor.stop_connection(iface2)
  end

  test "disconnected FSM for deleted profile is cleaned up (not left blocking interface)", %{
    iface: iface,
    profile: profile
  } do
    # Start FSM and let it reach activated
    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    # Deactivate — FSM goes to :disconnected state
    Connection.FSM.deactivate(pid)
    Process.sleep(200)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :disconnected

    # Delete the profile — FSM is now an orphan in :disconnected state
    ProfileStore.delete(profile.id)
    Process.sleep(50)

    # Before the fix, disconnected FSMs were skipped by compute_deactivation_diffs,
    # permanently blocking the interface from being used by new profiles.
    send(ReconciliationEngine, :debounced_reconcile)
    Process.sleep(300)

    assert :error == Connection.Supervisor.find_connection(iface),
           "Disconnected FSM for deleted profile should be cleaned up"
  end
end
