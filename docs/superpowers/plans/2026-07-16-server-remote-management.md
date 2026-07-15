# Server Remote Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `yellow_dog_server` release expose every approved Server domain through typed remote queries and commands, with durable agent journals, config activation, and rollback.

**Architecture:** `YellowDog.Server.Control` is the runtime-owned dispatch boundary. Domain adapters call existing Server applications and return wire-safe values with revisions. `yellow_dog_server_agent` maintains the outbound control connection, validates shared envelopes, persists idempotent results and config versions, and invokes the configured runtime adapter.

**Tech Stack:** Elixir/OTP, existing YellowDog Server domain apps, `phoenix_socket_client`, TOML validators, file-backed journals, ExUnit.

## Global Constraints

- Complete the shared control-plane plan first.
- Do not change DNS, DHCP, mDNS, or Netboot packet parsing or handling.
- Do not add raw `:gen_udp` calls.
- Do not call Concord directly from Server apps. Existing domain persistence boundaries remain authoritative.
- Do not add a generic Node or generic RPC abstraction.
- Do not report a mutation successful until its existing durable write and runtime activation have succeeded.
- Keep `YellowDog.ServiceManager` public APIs compatible.
- The agent must make no network call unless management URL, token, and concrete Server ID are configured.
- Use test adapters instead of starting privileged protocol listeners in unit tests.
- Preserve all pre-existing dirty worktree changes.

---

### Task 1: Establish the Server control dispatcher and revision contract

**Files:**
- Modify: `apps/yellow_dog/mix.exs`
- Create: `apps/yellow_dog/lib/yellow_dog/server/control.ex`
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/dispatcher.ex`
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/revision.ex`
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/result.ex`
- Create: `apps/yellow_dog/test/support/server_control_fake.ex`
- Create: `apps/yellow_dog/test/yellow_dog/server/control/dispatcher_test.exs`
- Create: `apps/yellow_dog/test/yellow_dog/server/control/revision_test.exs`

- [ ] Add `test/support` to test compilation and add `yellow_dog_sync` as an umbrella dependency.
- [ ] Test target-type enforcement, operation allowlisting, capability rejection, payload validation, bounded results, exception redaction, and no atom creation.
- [ ] Test deterministic revisions for normalized maps and explicit conflict results for stale `expected_revision` values.
- [ ] Run the focused tests and verify they fail on missing control modules.
- [ ] Implement one public dispatch entry point that accepts only a decoded, validated Server operation:

```elixir
@spec dispatch(YellowDog.Sync.Envelope.t()) ::
        {:ok, map()} | {:error, YellowDog.Sync.Error.t()}
def dispatch(%Envelope{target_type: :server} = envelope)
```

- [ ] Route by the operation registry's domain metadata to concrete adapter modules. Never accept a caller-supplied module or function.
- [ ] Normalize domain results before revision hashing; do not expose PIDs, ETS identifiers, Store records, structs without codecs, or local paths.
- [ ] Re-run focused tests and compile `yellow_dog` with warnings as errors.
- [ ] Commit with `feat(server): add typed control dispatcher`.

### Task 2: Implement runtime service reads and controls

**Files:**
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/runtime.ex`
- Modify: `apps/yellow_dog/lib/yellow_dog/server/control/dispatcher.ex`
- Modify: `apps/yellow_dog/lib/yellow_dog/service_manager.ex`
- Modify: `apps/yellow_dog/test/yellow_dog/service_manager_test.exs`
- Create: `apps/yellow_dog/test/yellow_dog/server/control/runtime_test.exs`

- [ ] Test capabilities, service list, health, status, and stats reads through `YellowDog.ServiceManager` and `YellowDog.Server.ServiceRegistry`.
- [ ] Test start, stop, and restart for controllable services, including unavailable skeleton services, already-started services, offline dependencies, and stale revisions.
- [ ] Test that `get_all_status/0`, `get_service_status/1`, `list_services/0`, `start_service/1`, `stop_service/1`, `get_service_stats/1`, and `format_status/1` retain existing return contracts.
- [ ] Run the focused tests and verify missing runtime adapter failures.
- [ ] Implement `YellowDog.Server.Control.Runtime` as a thin adapter. Restart must stop and then start the same allowlisted service and return both phase results if either fails.
- [ ] Include `server_agent` capability/status safely when its app is disabled, unloaded, or unavailable.
- [ ] Re-run ServiceManager and runtime control tests.
- [ ] Commit with `feat(server): expose runtime service controls`.

### Task 3: Implement DNS control operations without touching packet code

**Files:**
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/dns.ex`
- Modify: `apps/yellow_dog/lib/yellow_dog/server/control/dispatcher.ex`
- Create: `apps/yellow_dog/test/yellow_dog/server/control/dns_test.exs`
- Modify narrowly when required: `apps/yellow_dog_dns/lib/yellow_dog/dns/view_manager.ex`
- Modify narrowly when required: `apps/yellow_dog_dns/lib/yellow_dog/dns/view_store.ex`
- Modify narrowly when required: `apps/yellow_dog_dns/lib/yellow_dog/dns/zone_store.ex`
- Modify narrowly when required: `apps/yellow_dog_dns/lib/yellow_dog/dns/acl_store.ex`
- Modify narrowly when required: `apps/yellow_dog_dns/lib/yellow_dog/dns/config_persistence.ex`
- Modify narrowly when required: `apps/yellow_dog_dns/lib/yellow_dog/dns/cloud_dns_sync_job.ex`

- [ ] Add adapter tests for views, zones, records, ACLs, providers, logs, and metrics reads.
- [ ] Add mutation tests for view, zone, record, ACL, and provider create/update/delete; zone import; provider sync; and conflict resolution.
- [ ] Test stale revisions, malformed domain names and records, per-item bulk results, persistence failure, reload failure, and cloud task enqueue failure.
- [ ] Run tests and verify failures before adding the adapter.
- [ ] Call existing DNS stores/managers and `YellowDog.Tasks` entry points. Do not directly invoke Concord or packet modules.
- [ ] When an existing facade lacks a necessary durable operation, add the smallest public function to its owning store module and cover it there.
- [ ] Persist through `ConfigPersistence` before reporting success, then reload the affected view or zone. Restore the prior persisted value if reload fails.
- [ ] Keep DNS handler modules, `client.ex`, `server.ex`, protocol libraries, and response composition unchanged.
- [ ] Run DNS control tests plus existing DNS store/config tests.
- [ ] Commit with `feat(server): expose typed dns management`.

### Task 4: Implement DHCPv4 and DHCPv6 control operations

**Files:**
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/dhcpv4.ex`
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/dhcpv6.ex`
- Modify: `apps/yellow_dog/lib/yellow_dog/server/control/dispatcher.ex`
- Create: `apps/yellow_dog/test/yellow_dog/server/control/dhcpv4_test.exs`
- Create: `apps/yellow_dog/test/yellow_dog/server/control/dhcpv6_test.exs`
- Modify narrowly when required: `apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/lease_manager.ex`
- Modify narrowly when required: `apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/pool_store.ex`
- Modify narrowly when required: `apps/yellow_dog_dhcpv6/lib/yellow_dog/dhcpv6/lease_manager.ex`
- Modify narrowly when required: `apps/yellow_dog_dhcpv6/lib/yellow_dog/dhcpv6/pool_store.ex`

- [ ] Test pool, lease, activity, stats, and runtime-status reads for both protocol versions.
- [ ] Test pool add/update/remove, force removal, and lease release with canonical pool validators.
- [ ] Test stale revisions, active-lease protection, forced deletion, persistence failure, manager-not-running, and one result per bulk item.
- [ ] Run focused tests and observe the missing adapter failures.
- [ ] Implement adapters over `LeaseManager` and `PoolStore`; do not call packet handlers, servers, socket modules, or lease storage internals from the dispatcher.
- [ ] Persist pool changes before returning success. If runtime manager update fails, restore the previous pool file and manager state.
- [ ] Re-run focused tests plus existing pool-store and lease-manager tests.
- [ ] Commit with `feat(server): expose typed dhcp management`.

### Task 5: Implement mDNS control operations

**Files:**
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/mdns.ex`
- Modify: `apps/yellow_dog/lib/yellow_dog/server/control/dispatcher.ex`
- Create: `apps/yellow_dog/test/yellow_dog/server/control/mdns_test.exs`
- Modify narrowly when required: `apps/yellow_dog_mdns/lib/yellow_dog/mdns/service_registry.ex`
- Modify narrowly when required: `apps/yellow_dog_mdns/lib/yellow_dog/mdns/service_store.ex`
- Modify narrowly when required: `apps/yellow_dog_mdns/lib/yellow_dog/mdns/message_cache.ex`

- [ ] Test service, discovery, monitor, and cache reads.
- [ ] Test service register/update/delete/toggle and cache clear, including canonical validation and revision conflicts.
- [ ] Test persistence failure, responder unavailable, and bounded discovery/monitor result lists.
- [ ] Run focused tests and verify failure before implementation.
- [ ] Implement mutations through `ServiceRegistry` and `ServiceStore`, with persistence completed before success.
- [ ] Keep responder, handler, record parsing, and network-monitor protocol behavior unchanged.
- [ ] Re-run mDNS control and existing service-store tests.
- [ ] Commit with `feat(server): expose typed mdns management`.

### Task 6: Implement durable Netboot management

**Files:**
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/netboot.ex`
- Modify: `apps/yellow_dog/lib/yellow_dog/server/control/dispatcher.ex`
- Create: `apps/yellow_dog/test/yellow_dog/server/control/netboot_test.exs`
- Create: `apps/yellow_dog_netboot/lib/yellow_dog/netboot/boot/profile_persistence.ex`
- Modify: `apps/yellow_dog_netboot/lib/yellow_dog/netboot/manifest/store.ex`
- Modify: `apps/yellow_dog_netboot/lib/yellow_dog/netboot/device/registry.ex`
- Modify: `apps/yellow_dog_netboot/lib/yellow_dog/netboot/asset/store.ex`
- Create: `apps/yellow_dog_netboot/test/yellow_dog/netboot/boot/profile_persistence_test.exs`

- [ ] Test profiles, devices, assets, transfer state, and log reads.
- [ ] Test profile create/update/delete/default selection, device assignment/update/delete/reinstall, asset upload/delete/rescan, and bulk result behavior.
- [ ] Test restart persistence for profile mutations, atomic profile-file replacement, invalid relative paths, asset digest mismatch, and interrupted writes.
- [ ] Run tests and prove current `Manifest.Store` profile mutations disappear after restart.
- [ ] Add durable profile persistence in the Netboot app and load it before configured defaults. Preserve the existing Store-based in-memory API.
- [ ] Require asset upload metadata to reference an authenticated blob digest; stream to a temporary file, verify SHA-256, sync, and rename.
- [ ] Never send asset bytes through a channel envelope.
- [ ] Re-run Netboot persistence and Server control tests.
- [ ] Commit with `feat(netboot): persist remotely managed profiles`.

### Task 7: Implement Identity and Settings control operations

**Files:**
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/identity.ex`
- Create: `apps/yellow_dog/lib/yellow_dog/server/control/settings.ex`
- Modify: `apps/yellow_dog/lib/yellow_dog/server/control/dispatcher.ex`
- Create: `apps/yellow_dog/test/yellow_dog/server/control/identity_test.exs`
- Create: `apps/yellow_dog/test/yellow_dog/server/control/settings_test.exs`
- Modify narrowly when required: `apps/yellow_dog_identity/lib/yellow_dog_identity.ex`
- Modify narrowly when required: `apps/yellow_dog_identity/lib/yellow_dog_identity/registry.ex`
- Modify narrowly when required: `apps/yellow_dog_identity/lib/yellow_dog_identity/token.ex`
- Create: `apps/yellow_dog_config/lib/yellow_dog/config/manager.ex`
- Modify narrowly when required: `apps/yellow_dog_config/lib/yellow_dog/config/writer.ex`
- Create: `apps/yellow_dog_config/test/yellow_dog/config/manager_test.exs`

- [ ] Test Identity hosts, approvals, tokens, policies, and audit reads; host approve/revoke/delete; token create/revoke; and policy updates.
- [ ] Test Settings effective config, source, revision, validation, update, apply, reload, and service rollback operations.
- [ ] Test secret redaction, token one-time display, stale revisions, invalid TOML, atomic write failure, reload failure, and previous-config restoration.
- [ ] Run focused tests and observe failures before adding adapters.
- [ ] Use `YellowDogIdentity` public APIs and add only missing facade calls in the owning identity app.
- [ ] Move the console-independent load, validate, backup, update, and restore workflow into `YellowDog.Config.Manager`; use it with `YellowDog.Config.Writer` from the Server control adapter. Do not depend on `yellow_dog_console`, duplicate TOML encoding, or write config files directly from the dispatcher.
- [ ] Return revisions and sanitized values only.
- [ ] Re-run focused tests and existing config writer/manager tests.
- [ ] Commit with `feat(server): expose identity and settings management`.

### Task 8: Add durable Server-agent journals and config staging

**Files:**
- Modify: `apps/yellow_dog_server_agent/mix.exs`
- Create: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/storage.ex`
- Create: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/command_journal.ex`
- Create: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/config_store.ex`
- Create: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/dispatcher.ex`
- Modify: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/supervisor.ex`
- Create: `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/command_journal_test.exs`
- Create: `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/config_store_test.exs`
- Create: `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/dispatcher_test.exs`

- [ ] Add `yellow_dog_sync`, Jason, and `phoenix_socket_client` dependencies. Do not add a compile-time dependency on `yellow_dog`.
- [ ] Test journal replay after process restart, duplicate request replay without runtime invocation, bounded retention, corrupt files, and unknown outcomes.
- [ ] Test immutable config versions, current/previous manifests, digest verification, and cross-ID rejection.
- [ ] Test dispatcher target identity, capability checks, and configured runtime-adapter invocation.
- [ ] Run focused tests and verify failures before implementation.
- [ ] Configure the runtime adapter module, defaulting to `YellowDog.Server.Control`, and guard with `Code.ensure_loaded?/1`.
- [ ] Reuse the atomic immutable-version pattern from the shared design without depending on management core.
- [ ] Re-run all Server-agent tests.
- [ ] Commit with `feat(server-agent): add durable control state`.

### Task 9: Add outbound Server connection, config apply, and rollback

**Files:**
- Create: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/client.ex`
- Create: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/config_applier.ex`
- Create: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/runtime_adapter.ex`
- Modify: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/heartbeat.ex`
- Modify: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/status.ex`
- Modify: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/supervisor.ex`
- Modify: `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent.ex`
- Create: `apps/yellow_dog_server_agent/test/support/fake_runtime_adapter.ex`
- Create: `apps/yellow_dog_server_agent/test/support/fake_socket.ex`
- Create: `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/client_test.exs`
- Create: `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/config_applier_test.exs`

- [ ] Test no socket startup without URL, token, and Server ID.
- [ ] Test authenticated hello, reconnect backoff bounds, heartbeat/capability reports, command/result correlation, journal upload, malformed envelope rejection, and disconnect recovery.
- [ ] Test config phases: verify digest, stage, canonical validate, record previous, report applying, atomic install, activate, report applied.
- [ ] Test validation, write, and activation failures. Each must restore and reactivate the previous known-good config and record whether rollback succeeded.
- [ ] Run focused tests and observe failures before production code.
- [ ] Implement the socket client under the agent supervisor. The client initiates the outbound connection and joins only `server:control:<server_id>`.
- [ ] Implement config application through runtime-adapter callbacks:

```elixir
@callback validate_config(map()) :: :ok | {:error, term()}
@callback install_config(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
@callback activate_config(String.t()) :: :ok | {:error, term()}
@callback restore_config(String.t()) :: :ok | {:error, term()}
```

- [ ] Report `:applied` only after all four local phases complete. Bound and sanitize every failure reason.
- [ ] Re-run all agent tests and compile with warnings as errors.
- [ ] Commit with `feat(server-agent): connect and apply managed config`.

### Task 10: Wire the Server agent into the release

**Files:**
- Modify: `apps/yellow_dog/lib/yellow_dog/application.ex`
- Modify: `mix.exs`
- Modify: `config/runtime.exs`
- Create: `apps/yellow_dog/test/yellow_dog/application_test.exs`
- Modify: `apps/yellow_dog_server_agent/test/yellow_dog/server_agent_test.exs`

- [ ] Add tests proving the agent starts after the Server runtime when enabled and remains absent when disabled.
- [ ] Test safe startup when management is unavailable and when the agent app is missing from a custom release.
- [ ] Run tests and verify current release marks the agent only `:load`.
- [ ] Start `yellow_dog_server_agent` permanently in `yellow_dog_server`, while retaining combined development-release compatibility.
- [ ] Read management URL, token, concrete ID, local data directory, and reconnect limits from runtime configuration. Never log the token.
- [ ] Keep test defaults disabled.
- [ ] Re-run Server application, agent, and root release-configuration tests.
- [ ] Commit with `feat(server): start management agent in server release`.

### Task 11: Verify Server boundaries

**Files:**
- Modify only files required to resolve failures introduced by this plan.

- [ ] Run `devenv shell -- mix format --check-formatted`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog mix compile --warnings-as-errors`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog mix test`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_server_agent mix compile --warnings-as-errors`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_server_agent mix test`.
- [ ] Run focused tests for each modified protocol-domain store, manager, or registry.
- [ ] Run `git diff --name-only -- apps/abyss apps/ex_dns apps/ex_dhcp`; expect no output.
- [ ] Run `git diff -U0 | rg '^\+.*:gen_udp'`; expect no output.
- [ ] Run `git diff --name-only | rg '(handler|packet|protocol|response_composer)'`; inspect and require no protocol-path changes.
- [ ] Run `rg -n 'Concord\.' apps/yellow_dog apps/yellow_dog_* | rg -v 'yellow_dog_store'`; verify this plan added no direct call.
- [ ] Run `git diff --check`.
- [ ] Commit verification-only corrections with `fix(server): satisfy remote management guardrails` when needed. Do not create an empty commit.

## Completion Evidence

Record each command and result. This plan is complete only when every Server operation in the approved domain table has a typed test, durable mutations survive restart, duplicate commands do not repeat mutations, activation rollback is proven, and no protocol parser or packet handler changed.
