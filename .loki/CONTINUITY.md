# Session Continuity

Updated: 2026-03-12T23:00:00Z

## Current State

- Iteration: 6
- Phase: IMPLEMENTATION
- Provider: claude
- Elapsed: 76h 00m

## Last Completed Task

- Last commit: fix(netman/fsm): auto-reactivate after method change and flush stale routes on priority update

## Fixes This Session

1. `fix(identity,yellow_dog)`: Resolve named Registry collision in identity tests (133 failures → 0)
2. `fix(yellow_dog)`: Accept :module_not_available in ServiceManager test for release profiles
3. `feat(netman)`: Add LeaseCoordinator to bridge DHCP telemetry → FSM (critical prod blocker)
4. `fix(netman/fsm)`: Log DNS push/reset failures instead of silently swallowing
5. `feat(netman)`: Add IPv6 static address and route reconciliation
6. `test(netman)`: Add DHCP telemetry flow integration tests (4 tests)
7. `docs(netman)`: Update CLAUDE.md with LeaseCoordinator; fix whois format
8. `fix(identity)`: Extract TestHelper.stop_app_identity() — robust cleanup with retry, monitor, delete_child
9. `fix(netman/fsm)`: Handle carrier loss during :prepare and :ip_check states (was silently swallowed)
10. `feat(netman)`: Implement compute_deactivation_diffs — auto-deactivate orphaned FSMs when profiles deleted
11. `feat(netman)`: Add DNS search domain support to profiles, reconciliation, and FSM push_dns
12. `fix(netman/fsm)`: Correct IPv6 SLAAC handling — configure_ip waits for SLAAC, ip_check validates both families, activated monitors IPv6 address removal
13. `feat(netman)`: Profile hot-reload pushes updated profiles to running FSMs
14. `fix(netman/fsm)`: Auto-reactivate after method change deactivation; flush stale routes on non-method profile update

## Active Blockers

- None

## Next Up

- SecretStore implementation (currently a stub — Phase 1 PRD says file-based backend)
- API.CLI: all PRD methods implemented, consider `connection.update` for profile modification

## Mistakes & Learnings

- YellowDog core app auto-starts identity/netman services (all services default enabled)
  → Tests that start named processes must first stop the app-managed instance AND its supervisor
  → Pattern: terminate_child + delete_child from YellowDog.Supervisor, then monitor-based stop
  → The async Task from start_services_async races with test setup — use retry loop with 50ms sleep
- `start_supervised!` fails with `{:already_started, _}` when app supervisor owns the process
  → For processes owned by app supervisors, just use the existing one in tests
  → Or use TestHelper.stop_app_identity() which handles the full cleanup
- DHCP client emits :bound (not :acquired), :renewed, :expired telemetry — map accordingly
- IPv6 reconciliation was completely missing — always check both protocol families
- Carrier loss in :prepare/:ip_check states was silently swallowed by catch-all
  → Must explicitly handle carrier: false in ALL active states
- compute_deactivation_diffs: tests that start FSMs with long sleeps (>100ms debounce)
  MUST register profiles in ProfileStore or the ReconciliationEngine will auto-deactivate them
  → FSMDhcpCoverageTest was the first casualty (300ms sleep + no ProfileStore registration)
- FSM ip_check `ipv4.method == :disabled` bypass was wrong — it passed without any address
  even when IPv6 :auto expected a SLAAC address. Must check BOTH protocols.
- Mock netlink `Netlink.command` is a no-op — addresses only enter ETS via events.
  Tests for static IPv6 must call `MockNetlink.address_added` to simulate kernel response.
- Profile hot-reload architecture: don't compute update diffs in the stateless diff pipeline
  (breaks idempotency). Instead push profiles directly via event-driven approach.
- Method change deactivation must auto-reactivate: FSM process still exists in :disconnected,
  so reconciliation won't spawn a new one. Use a `reactivate` flag in FSM data to trigger
  auto_activate after cleanup completes.
- Non-method profile changes (priority) in activated state must flush old routes before
  installing new ones — otherwise stale routes with wrong metrics remain.
