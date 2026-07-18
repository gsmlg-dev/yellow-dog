# Netman Remote Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `yellow_dog_netman` release expose typed, selected-instance reads and mutations with durable profiles, reconciliation-owned activation, idempotent agent delivery, and autonomous connectivity rollback.

**Architecture:** `YellowDog.Netman.Control` is the runtime-owned boundary over profiles, reconciliation, connections, Resolved, and DHCP client state. `yellow_dog_netman_agent` owns the outbound management connection and durable delivery state. All network changes pass through profiles and `ReconciliationEngine`; the agent never calls kernel managers directly.

**Tech Stack:** Elixir/OTP, `phoenix_socket_client`, existing Netman/Resolved/DHCP client APIs, TOML profiles, file-backed journals, ExUnit with mock netlink support.

## Global Constraints

- Complete the shared control-plane plan first.
- Do not add `yellow_dog_store`, Concord, Mnesia, Ecto, or migrations to Netman or NetmanAgent.
- Do not add a generic Node model or generic RPC.
- Do not modify DHCP packet parsing or introduce raw `:gen_udp` calls.
- Preserve `YellowDog.Netman` public APIs.
- Mutations in `:observe` mode return `unsupported`. `:observe_first` requires the existing policy/reconciliation gate before mutation.
- Persist profiles before applying them. Apply changes through `ReconciliationEngine`, not kernel managers.
- VPN remains configuration state only; do not add a tunnel implementation.
- The agent makes no network call unless management URL, token, and concrete Netman ID are configured.
- Preserve all pre-existing dirty worktree changes.

---

### Task 1: Make Netman profile mutations durable and revisioned

**Files:**
- Modify: `apps/yellow_dog_netman/lib/yellow_dog/netman/profile_store.ex`
- Modify: `apps/yellow_dog_netman/lib/yellow_dog/netman/types/profile.ex`
- Modify: `apps/yellow_dog_netman/lib/yellow_dog/netman.ex`
- Modify: `apps/yellow_dog_netman/test/test_helper.exs`
- Modify: `apps/yellow_dog_netman/test/profile_store_test.exs`
- Modify: `apps/yellow_dog_netman/test/profile_store_coverage_test.exs`
- Create: `apps/yellow_dog_netman/test/profile_store_durability_test.exs`
- Modify: `config/test.exs`

- [x] Add tests proving `put/2` creates or atomically replaces `<profile_dir>/<id>.toml`, updates in-memory state only after the write, and survives process restart.
- [x] Add tests proving `delete/1` removes the backing file before removing memory state and does not resurrect through watcher events.
- [x] Test ID/file-name validation, TOML round trip through `Profile.from_toml/1`, stale expected revision, write/delete failures, temporary-file cleanup, and watcher self-events.
- [x] Run focused tests and verify current memory-only `put/2` and `delete/1` fail restart durability.
- [x] Extend the API without breaking callers:

```elixir
put(id, profile)
put(id, profile, expected_revision: revision)
delete(id)
delete(id, expected_revision: revision)
revision(id)
```

- [x] Generate revisions from canonical `Profile.to_toml/1` output.
- [x] Write, sync, close, and same-directory rename before updating the cache or publishing `netman:profile:changed`.
- [x] Keep import validation in `Profile.from_toml/1`; do not add a second profile parser.
- [x] Re-run all ProfileStore tests and compile Netman with warnings as errors.
- [x] Commit with `feat(netman): persist profile mutations`.

### Task 2: Add the Netman control dispatcher and apply-mode gate

**Files:**
- Modify: `apps/yellow_dog_netman/mix.exs`
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control.ex`
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/dispatcher.ex`
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/mode_gate.ex`
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/revision.ex`
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/result.ex`
- Create: `apps/yellow_dog_netman/test/control/dispatcher_test.exs`
- Create: `apps/yellow_dog_netman/test/control/mode_gate_test.exs`

- [ ] Add `yellow_dog_sync` as an umbrella dependency. Do not add Store.
- [ ] Test target-type checks, operation allowlisting, capability checks, input bounds, result normalization, exception redaction, and atom safety.
- [ ] Test query permission in all apply modes; mutation rejection in `:observe`; and explicit approval/policy behavior in `:observe_first`.
- [ ] Test conflict results against canonical resource revisions.
- [ ] Run focused tests and verify missing-module failures.
- [ ] Implement one public entry point accepting only validated Netman envelopes:

```elixir
@spec dispatch(YellowDog.Sync.Envelope.t()) ::
        {:ok, map()} | {:error, YellowDog.Sync.Error.t()}
def dispatch(%Envelope{target_type: :netman} = envelope)
```

- [ ] Read apply mode from the running Netman supervisor/profile state. Do not trust a mode in the incoming payload.
- [ ] Map every operation to a fixed domain adapter and return wire-safe data without PIDs, ports, or local paths.
- [ ] Re-run dispatcher tests and compile with warnings as errors.
- [ ] Commit with `feat(netman): add typed control dispatcher`.

### Task 3: Expose runtime, profile, interface, route, and connection operations

**Files:**
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/runtime.ex`
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/profiles.ex`
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/network.ex`
- Modify: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/dispatcher.ex`
- Modify narrowly when required: `apps/yellow_dog_netman/lib/yellow_dog/netman/reconciliation_engine.ex`
- Modify narrowly when required: `apps/yellow_dog_netman/lib/yellow_dog/netman/connection/supervisor.ex`
- Create: `apps/yellow_dog_netman/test/control/runtime_test.exs`
- Create: `apps/yellow_dog_netman/test/control/profiles_test.exs`
- Create: `apps/yellow_dog_netman/test/control/network_test.exs`

- [ ] Test capabilities, apply mode, reconciliation health, profiles, active revision, history, interfaces, addresses, routes, links, and connection-state reads.
- [ ] Test profile validate/put/delete/activate/rollback; profile patch; and connection activate/deactivate.
- [ ] Test stale revisions, missing interfaces, no matching interface, reconciliation errors, observe-mode rejections, and one explicit result per bulk item.
- [ ] Run focused tests and observe failures before implementation.
- [ ] Use `YellowDog.Netman`, `ProfileStore`, `Connection.Supervisor`, and `ReconciliationEngine` as the only mutation entry points.
- [ ] Add a synchronous reconciliation result API when required so remote success means reconciliation completed, not merely that a cast was accepted.
- [ ] Build profile history from durable profile versions; do not infer it from transient events.
- [ ] Keep `AddressManager`, `RouteManager`, `RuleManager`, and netlink calls behind reconciliation and read-only observation code.
- [ ] Re-run control tests plus reconciliation and ProfileStore suites.
- [ ] Commit with `feat(netman): expose profiles and network controls`.

### Task 4: Expose Resolved and DHCP client operations

**Files:**
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/resolved.ex`
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/dhcp_client.ex`
- Modify: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/dispatcher.ex`
- Modify narrowly when required: `apps/yellow_dog_resolved/lib/yellow_dog/resolved.ex`
- Modify narrowly when required: `apps/yellow_dog_resolved/lib/yellow_dog/resolved/config.ex`
- Modify narrowly when required: `apps/yellow_dog_dhcp_client/lib/yellow_dog/dhcp_client.ex`
- Create: `apps/yellow_dog_netman/test/control/resolved_test.exs`
- Create: `apps/yellow_dog_netman/test/control/dhcp_client_test.exs`

- [ ] Test Resolved upstreams, search domains, per-link DNS, cache, counters, and recent-query reads.
- [ ] Test Resolved update, rollback, and cache flush with canonical config validation and revision conflicts.
- [ ] Test DHCP client FSM/lease reads and release through the owning connection/interface.
- [ ] Test invalid DNS endpoints/search domains, write failure, runtime apply failure, prior-config restoration, absent FSM, and observe-mode rejection.
- [ ] Run focused tests and verify failures before implementation.
- [ ] Add the smallest required public Resolved configuration facade. Persist the previous configuration, update runtime components, and restore on partial failure.
- [ ] Call `YellowDog.DhcpClient.release/1`; do not interact with its state machine, socket, or packet module directly.
- [ ] Keep DHCP packet and socket files unchanged.
- [ ] Re-run control tests plus focused Resolved config and DHCP client facade tests.
- [ ] Commit with `feat(netman): expose resolved and dhcp client controls`.

### Task 5: Add VPN configuration-state reads only

**Files:**
- Create: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/vpn.ex`
- Modify: `apps/yellow_dog_netman/lib/yellow_dog/netman/control/dispatcher.ex`
- Create: `apps/yellow_dog_netman/test/control/vpn_test.exs`

- [ ] Test that `vpn_gateway` and custom profile state can be queried and revisioned.
- [ ] Test that every tunnel start/stop/peer mutation operation is absent from the allowlist and returns `unsupported`.
- [ ] Run tests and verify the VPN adapter is missing.
- [ ] Implement read-only projection of resolved profile VPN state. Do not create sockets, interfaces, routes, peers, key generation, or tunnel processes.
- [ ] Re-run focused tests.
- [ ] Commit with `feat(netman): expose vpn profile state`.

### Task 6: Add durable Netman-agent journals and config storage

**Files:**
- Modify: `apps/yellow_dog_netman_agent/mix.exs`
- Create: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/storage.ex`
- Create: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/command_journal.ex`
- Create: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/config_store.ex`
- Create: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/dispatcher.ex`
- Modify: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/supervisor.ex`
- Create: `apps/yellow_dog_netman_agent/test/yellow_dog/netman_agent/command_journal_test.exs`
- Create: `apps/yellow_dog_netman_agent/test/yellow_dog/netman_agent/config_store_test.exs`
- Create: `apps/yellow_dog_netman_agent/test/yellow_dog/netman_agent/dispatcher_test.exs`

- [ ] Add `yellow_dog_sync`, Jason, and `phoenix_socket_client` dependencies. Do not add Netman or Store as compile-time dependencies.
- [ ] Test restart durability, duplicate command replay, bounded journal retention, unknown result state, corrupt files, and target-ID isolation.
- [ ] Test immutable config versions, digest verification, current/previous manifests, and version ordering.
- [ ] Test configured adapter dispatch, capability checks, target identity, and unavailable runtime adapter.
- [ ] Run focused tests and verify failures before implementation.
- [ ] Configure the runtime adapter module, defaulting to `YellowDog.Netman.Control`, and guard with `Code.ensure_loaded?/1`.
- [ ] Use immutable files and atomic manifests under the agent data directory, independent of management-core storage.
- [ ] Re-run all Netman-agent tests.
- [ ] Commit with `feat(netman-agent): add durable control state`.

### Task 7: Move the outbound management client into NetmanAgent

**Files:**
- Create: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/client.ex`
- Create: `apps/yellow_dog_netman_agent/test/support/fake_socket.ex`
- Create: `apps/yellow_dog_netman_agent/test/support/fake_runtime_adapter.ex`
- Create: `apps/yellow_dog_netman_agent/test/yellow_dog/netman_agent/client_test.exs`
- Modify: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/heartbeat.ex`
- Modify: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/status.ex`
- Modify: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/supervisor.ex`
- Modify: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent.ex`
- Delete after migration: `apps/yellow_dog_netman/lib/yellow_dog/netman/console/client.ex`
- Modify: `apps/yellow_dog_netman/mix.exs`

- [ ] Test no socket startup without URL, token, and Netman ID.
- [ ] Test authenticated hello, bounded reconnect backoff, heartbeat/capabilities, command/result correlation, journal upload, malformed messages, and reconnect.
- [ ] Test joining only `netman:control:<netman_id>` and rejecting identity changes after join.
- [ ] Run focused tests and verify failure before implementation.
- [ ] Port the proven reconnect mechanics from the existing Netman console client into the agent. Replace ad hoc status payloads with typed sync messages.
- [ ] Remove `phoenix_socket_client` and the old client from `yellow_dog_netman` after the agent owns the connection.
- [ ] Ensure telemetry/status streaming still flows through typed events or snapshots.
- [ ] Re-run Netman-agent tests and Netman application supervision tests.
- [ ] Commit with `refactor(netman): move management connection to agent`.

### Task 8: Implement Netman config apply and autonomous rollback

**Files:**
- Create: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/config_applier.ex`
- Create: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/rollback_timer.ex`
- Create: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/runtime_adapter.ex`
- Modify: `apps/yellow_dog_netman_agent/lib/yellow_dog/netman_agent/supervisor.ex`
- Create: `apps/yellow_dog_netman_agent/test/yellow_dog/netman_agent/config_applier_test.exs`
- Create: `apps/yellow_dog_netman_agent/test/yellow_dog/netman_agent/rollback_timer_test.exs`

- [ ] Test digest verification, durable stage, canonical profile validation, previous-version capture, applying state, profile install, reconciliation, and applied acknowledgement.
- [ ] Test validation, write, and reconcile failures with automatic restoration and reconciliation of the previous known-good profile.
- [ ] Test connectivity-changing updates remain provisional until the agent reconnects within the configured window.
- [ ] Test timer persistence across agent restart, successful reconnect cancellation, timeout rollback, rollback failure, and bounded reporting.
- [ ] Run focused tests and verify failures before implementation.
- [ ] Define runtime callbacks around profiles and reconciliation:

```elixir
@callback validate_config(map()) :: :ok | {:error, term()}
@callback install_config(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
@callback reconcile(String.t()) :: :ok | {:error, term()}
@callback restore_config(String.t()) :: :ok | {:error, term()}
```

- [ ] Classify connectivity-changing fields explicitly: interface match, addresses, DHCP mode, routes, DNS, and policy priority.
- [ ] Write the rollback deadline to disk before applying connectivity-changing state.
- [ ] Do not mark applied until non-connectivity changes reconcile, or connectivity changes reconcile and reconnect.
- [ ] Re-run all config-applier and rollback tests.
- [ ] Commit with `feat(netman-agent): apply config with reconnect rollback`.

### Task 9: Wire NetmanAgent into the Netman release

**Files:**
- Modify: `apps/yellow_dog_netman/lib/yellow_dog/netman/application.ex`
- Modify: `mix.exs`
- Modify: `config/runtime.exs`
- Modify: `apps/yellow_dog_netman/test/yellow_dog/netman/application_test.exs`
- Modify: `apps/yellow_dog_netman_agent/test/yellow_dog/netman_agent_test.exs`

- [ ] Test child ordering: Resolved as configured, Netman supervisor, then enabled agent.
- [ ] Test disabled agent, unsupported platform behavior, management unavailable startup, and a custom release without the agent module.
- [ ] Run tests and verify current root release marks NetmanAgent only `:load`.
- [ ] Start `yellow_dog_netman_agent` permanently in `yellow_dog_netman` after runtime children.
- [ ] Read management URL, token, concrete ID, local data directory, reconnect limits, and rollback window from runtime config without logging secrets.
- [ ] Preserve profile-driven feature startup and test-default disablement.
- [ ] Re-run Netman application and agent tests.
- [ ] Commit with `feat(netman): start management agent in netman release`.

### Task 10: Verify Netman isolation and protocol safety

**Files:**
- Modify only files required to resolve failures introduced by this plan.

- [ ] Run `devenv shell -- mix format --check-formatted`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_netman mix compile --warnings-as-errors`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_netman mix test`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_netman_agent mix compile --warnings-as-errors`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_netman_agent mix test`.
- [ ] Run focused tests for modified Resolved and DHCP client facades.
- [ ] Run `rg -n 'yellow_dog_store|YellowDog\.Store|Concord|Mnesia' apps/yellow_dog_netman apps/yellow_dog_netman_agent`; expect no runtime dependency or call.
- [ ] Run `git diff -U0 | rg '^\+.*:gen_udp'`; expect no output.
- [ ] Run `git diff --name-only -- apps/yellow_dog_dhcp_client/lib/yellow_dog/dhcp_client/packet.ex apps/yellow_dog_dhcp_client/lib/yellow_dog/dhcp_client/dhcp_socket.ex`; expect no output.
- [ ] Run `git diff --check`.
- [ ] Commit verification-only corrections with `fix(netman): satisfy remote management guardrails` when needed. Do not create an empty commit.

## Completion Evidence

Record every command and result. This plan is complete only when all Netman operations in the approved table have typed tests, profiles survive restart, observe modes block unsafe writes, duplicate commands are idempotent, connectivity rollback is proven across process restart, and Store/protocol safety scans are clean.
