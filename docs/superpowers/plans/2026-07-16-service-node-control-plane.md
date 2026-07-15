# Service Node Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the typed synchronization contracts and durable management-core state needed to manage concrete YellowDog Server and Netman instances.

**Architecture:** `yellow_dog_sync` owns bounded, versioned transport values and operation allowlists. `yellow_dog_management_core` owns concrete Server and Netman registrations, immutable config versions, command results, snapshots, events, and a transport behaviour. Phoenix and runtime applications remain outside both apps.

**Tech Stack:** Elixir 1.18, OTP, ExUnit, Jason, file-backed JSON, atomic same-directory rename.

## Global Constraints

- Follow [the approved design](../specs/2026-07-15-service-node-remote-management-design.md).
- Do not define `YellowDog.Domain.Node`, `YellowDog.Management.Node`, `YellowDog.Node`, or another generic Node struct.
- The only target types are `:server` and `:netman`.
- Do not add Ecto, migrations, Mnesia, Concord, Store, Phoenix, or protocol-runtime dependencies to either app.
- Do not add an arbitrary RPC operation. Every operation must be in a concrete allowlist.
- Validate IDs before constructing paths. Bound every externally supplied string and collection.
- Preserve the existing management-core facade APIs while adding new APIs.
- Preserve all pre-existing dirty worktree changes.
- Write each test first and observe the expected failure before adding production code.

## Cross-Plan Contracts

| Value | Internal type | Wire/storage form |
| --- | --- | --- |
| Target type | `:server | :netman` | `"server" | "netman"` |
| Concrete target ID | `String.t()` | validated UTF-8 string, maximum 128 bytes |
| Request ID | `String.t()` | lowercase UUID string |
| Idempotency key | `String.t()` | lowercase UUID string |
| Operation | `String.t()` | exact allowlisted dotted name |
| Config version | `pos_integer()` | JSON integer |
| Resource revision | `String.t()` | lowercase SHA-256 hex |
| Payload digest | `String.t()` | lowercase SHA-256 hex |
| Timestamp | `DateTime.t()` | UTC ISO 8601 string |
| Error | `YellowDog.Sync.Error.t()` | stable string code, bounded message, field details |

Do not change these representations in the Server, Netman, console, or E2E plans. A decoder may convert only the fixed target types and error codes to existing atoms. Operation names remain strings through dispatch.

## Execution Order

1. Complete this control-plane plan.
2. Execute the Server and Netman plans in parallel after Task 3 establishes the shared operation registry and after all management-core tasks pass.
3. Execute the console and release-E2E plan after both runtime plans expose their complete typed contracts.

---

### Task 1: Scaffold `yellow_dog_sync` and stable error values

**Files:**
- Create: `apps/yellow_dog_sync/mix.exs`
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync.ex`
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync/error.ex`
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync/bounds.ex`
- Create: `apps/yellow_dog_sync/test/test_helper.exs`
- Create: `apps/yellow_dog_sync/test/yellow_dog/sync/error_test.exs`
- Create: `apps/yellow_dog_sync/test/yellow_dog/sync/bounds_test.exs`

- [ ] Add tests proving that only these error codes are accepted: `not_connected`, `not_found`, `invalid`, `conflict`, `unsupported`, `timeout`, `apply_failed`, `rollback_failed`, and `internal`.
- [ ] Add tests for maximum ID, operation, message, map, list, and payload sizes. Include boundary values and one-over-limit values.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_sync mix test`; verify it fails because the app and modules do not exist.
- [ ] Scaffold a library-only umbrella app with `:crypto` in `extra_applications` and Jason as its only runtime dependency.
- [ ] Implement `%YellowDog.Sync.Error{code, message, details}` with `new/3`, `from_wire/1`, and `to_wire/1`. Never convert external strings with `String.to_atom/1`.
- [ ] Implement `YellowDog.Sync.Bounds` functions that return `{:ok, value}` or `{:error, %YellowDog.Sync.Error{code: :invalid}}`.
- [ ] Keep the public facade small:

```elixir
defmodule YellowDog.Sync do
  alias YellowDog.Sync.Envelope

  def encode(%Envelope{} = envelope), do: Envelope.encode(envelope)
  def decode(payload), do: Envelope.decode(payload)
end
```

- [ ] Re-run `devenv shell -- mix cmd --app yellow_dog_sync mix test`; verify all new tests pass.
- [ ] Run `devenv shell -- mix format apps/yellow_dog_sync`.
- [ ] Commit only this task with `feat(sync): add bounded control protocol values`.

### Task 2: Add versioned envelopes, identities, digests, and codecs

**Files:**
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync/envelope.ex`
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync/identity.ex`
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync/digest.ex`
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync/codec.ex`
- Create: `apps/yellow_dog_sync/test/yellow_dog/sync/envelope_test.exs`
- Create: `apps/yellow_dog_sync/test/yellow_dog/sync/identity_test.exs`
- Create: `apps/yellow_dog_sync/test/yellow_dog/sync/digest_test.exs`

- [ ] Test JSON round trips for Server and Netman envelopes with all required fields.
- [ ] Test rejection of missing fields, unknown protocol versions, malformed UUID request IDs, invalid target IDs, target-type mismatches, oversized payloads, and incorrect SHA-256 digests.
- [ ] Test that decoding a large set of unknown operation strings does not grow the atom table.
- [ ] Run the new tests and verify failures identify the missing envelope modules.
- [ ] Implement an envelope with these required keys:

```elixir
@enforce_keys [
  :protocol_version,
  :request_id,
  :target_type,
  :target_id,
  :operation,
  :idempotency_key,
  :payload,
  :payload_digest,
  :sent_at
]
defstruct @enforce_keys ++ [expected_revision: nil]
```

- [ ] Keep `target_type` decoding explicit with clauses for only `"server"` and `"netman"`.
- [ ] Implement separate `%Identity.Server{}` and `%Identity.Netman{}` structs containing ID, name, version, profile, capabilities, and current config revision.
- [ ] Canonicalize JSON before hashing so the sender and receiver compute the same lowercase SHA-256 hex digest.
- [ ] Return stable `YellowDog.Sync.Error` values from every decoder failure.
- [ ] Re-run `devenv shell -- mix cmd --app yellow_dog_sync mix test`; verify all tests pass.
- [ ] Commit with `feat(sync): add versioned control envelopes`.

### Task 3: Add concrete Server and Netman operation allowlists

**Files:**
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync/operation.ex`
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync/server_operation.ex`
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync/netman_operation.ex`
- Create: `apps/yellow_dog_sync/lib/yellow_dog/sync/message.ex`
- Create: `apps/yellow_dog_sync/test/yellow_dog/sync/server_operation_test.exs`
- Create: `apps/yellow_dog_sync/test/yellow_dog/sync/netman_operation_test.exs`
- Create: `apps/yellow_dog_sync/test/yellow_dog/sync/message_test.exs`

- [ ] Write table-driven tests covering every read and mutation listed in the design's Server and Netman domain tables.
- [ ] Test that each operation has an explicit target type, kind (`:query`, `:command`, or `:config`), payload validator, result validator, online requirement, and capability.
- [ ] Test rejection of unknown names without atom creation.
- [ ] Run the focused tests and verify they fail on missing registries.
- [ ] Implement string-keyed lookup tables. Representative entries must have this shape:

```elixir
%{
  "server.runtime.services.list" => %Operation{
    target_type: :server,
    kind: :query,
    capability: "runtime.services",
    payload_schema: :empty,
    result_schema: :service_list,
    online?: true
  },
  "netman.profiles.put" => %Operation{
    target_type: :netman,
    kind: :command,
    capability: "profiles.write",
    payload_schema: :profile_put,
    result_schema: :revisioned_resource,
    online?: true
  }
}
```

- [ ] Include message structs/codecs for `hello`, `heartbeat`, `status`, `query`, `command`, `result`, `config_delivery`, `config_state`, `journal`, and `event`.
- [ ] Validate operation-specific payloads before an envelope can reach management or a runtime dispatcher.
- [ ] Re-run all `yellow_dog_sync` tests and `mix compile --warnings-as-errors` for the app.
- [ ] Commit with `feat(sync): add typed server and netman operations`.

### Task 4: Add safe atomic JSON persistence primitives

**Files:**
- Modify: `apps/yellow_dog_management_core/mix.exs`
- Create: `apps/yellow_dog_management_core/lib/yellow_dog/management/storage/path.ex`
- Create: `apps/yellow_dog_management_core/lib/yellow_dog/management/storage/atomic_json.ex`
- Create: `apps/yellow_dog_management_core/test/yellow_dog/management/storage/path_test.exs`
- Create: `apps/yellow_dog_management_core/test/yellow_dog/management/storage/atomic_json_test.exs`

- [ ] Add tests for accepted IDs, traversal attempts, absolute paths, separators, overlong IDs, immutable create-once writes, durable manifest replacement, corrupt JSON, and interrupted temporary files.
- [ ] Use a unique temporary directory per test and remove it in `on_exit/1`.
- [ ] Run the focused tests and verify they fail because storage modules are absent.
- [ ] Add `{:jason, "~> 1.2"}` and `{:yellow_dog_sync, in_umbrella: true}` to management-core dependencies.
- [ ] Implement paths rooted at `Application.get_env(:yellow_dog_management_core, :data_dir)` with a production default under the configured YellowDog data directory.
- [ ] Implement immutable writes with exclusive creation. Implement mutable writes with a same-directory temporary file, `:file.sync/1`, close, and rename.
- [ ] Ensure all path constructors receive an already validated concrete Server ID, Netman ID, request ID, event ID, domain, version, or digest.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_management_core mix test test/yellow_dog/management/storage` and verify all tests pass.
- [ ] Commit with `feat(management): add atomic file persistence`.

### Task 5: Persist concrete registrations and events across restart

**Files:**
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management/servers.ex`
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management/netmans.ex`
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management/event.ex`
- Create: `apps/yellow_dog_management_core/lib/yellow_dog/management/event_store.ex`
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management_core/application.ex`
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management_core.ex`
- Modify: `apps/yellow_dog_management_core/test/yellow_dog/management_core_test.exs`
- Create: `apps/yellow_dog_management_core/test/yellow_dog/management/restart_durability_test.exs`

- [ ] Extend tests to stop and restart each registry and prove that concrete Server and Netman records, status, last-seen timestamps, and ordered events survive.
- [ ] Test registration replacement, configured limits, malformed on-disk files, and deterministic ordering.
- [ ] Run the tests and verify current in-memory registries lose records after restart.
- [ ] Back `Servers` and `Netmans` with concrete manifest paths. Do not merge them into a generic target registry.
- [ ] Persist each event before exposing it through `list_events/0`. Keep bounded reads while retaining immutable audit files.
- [ ] Preserve these existing facade contracts exactly: `list_servers/0`, `get_server/1`, `register_server/1`, `update_server_status/2`, `list_netmans/0`, `get_netman/1`, `register_netman/1`, `update_netman_status/2`, profile list functions, and `list_events/0`.
- [ ] Re-run all management-core tests and verify restart durability.
- [ ] Commit with `feat(management): persist service registrations and events`.

### Task 6: Implement config-version lifecycle and latest-desired delivery

**Files:**
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management/config_version.ex`
- Create: `apps/yellow_dog_management_core/lib/yellow_dog/management/config_versions.ex`
- Create: `apps/yellow_dog_management_core/test/yellow_dog/management/config_versions_test.exs`
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management_core/application.ex`
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management_core.ex`

- [ ] Test immutable monotonically increasing versions separately for each concrete target.
- [ ] Test the allowed transitions `desired -> delivered -> applying -> applied` and failures from delivery or apply phases.
- [ ] Test rejection of skipped, repeated, backward, cross-target, and stale expected-revision transitions.
- [ ] Test that publishing while offline advances only the durable desired pointer and that reconnect returns only the latest desired version.
- [ ] Test restart durability for desired/applied pointers, digest, payload, rollback result, failure phase, bounded reason, and restored version.
- [ ] Run tests and verify the placeholder struct cannot provide this behavior.
- [ ] Implement explicit facade functions:

```elixir
publish_server_config(server_id, attrs)
publish_netman_config(netman_id, attrs)
get_server_config_version(server_id, version)
get_netman_config_version(netman_id, version)
transition_config(target_type, target_id, version, state, details)
latest_desired_config(target_type, target_id)
```

- [ ] Write immutable version JSON first, then atomically advance `manifest.json`.
- [ ] Do not mark a version `:applied` without an agent acknowledgement containing the same target, version, and digest.
- [ ] Re-run management-core tests and compile with warnings as errors.
- [ ] Commit with `feat(management): persist desired config lifecycle`.

### Task 7: Add durable commands, snapshots, and the transport boundary

**Files:**
- Create: `apps/yellow_dog_management_core/lib/yellow_dog/management/transport.ex`
- Create: `apps/yellow_dog_management_core/lib/yellow_dog/management/disconnected_transport.ex`
- Create: `apps/yellow_dog_management_core/lib/yellow_dog/management/commands.ex`
- Create: `apps/yellow_dog_management_core/lib/yellow_dog/management/snapshots.ex`
- Create: `apps/yellow_dog_management_core/test/support/fake_transport.ex`
- Create: `apps/yellow_dog_management_core/test/yellow_dog/management/commands_test.exs`
- Create: `apps/yellow_dog_management_core/test/yellow_dog/management/snapshots_test.exs`
- Create: `apps/yellow_dog_management_core/test/yellow_dog/management/transport_test.exs`
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management_core/application.ex`
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management_core.ex`
- Modify: `apps/yellow_dog_management_core/mix.exs`

- [ ] Add a test-only compile path for `test/support`.
- [ ] Test that queries and commands reject offline targets with `not_connected` and never enter a queue.
- [ ] Test request correlation, timeout, idempotency replay, expected-revision conflict, unknown outcome after disconnect, and journal-based resolution after reconnect.
- [ ] Test timestamped, revisioned snapshots by concrete target and domain, including restart durability and missing-snapshot behavior.
- [ ] Test that a fake transport receives only validated `YellowDog.Sync.Envelope` values.
- [ ] Run focused tests and verify failures before implementation.
- [ ] Define this behaviour without referencing Phoenix:

```elixir
@callback connected?(:server | :netman, String.t()) :: boolean()
@callback request(YellowDog.Sync.Envelope.t(), timeout()) ::
            {:ok, map()} | {:error, YellowDog.Sync.Error.t()}
@callback deliver_config(YellowDog.Sync.Envelope.t()) ::
            :ok | {:error, YellowDog.Sync.Error.t()}
```

- [ ] Expose separate facade entry points `query_server/4`, `command_server/5`, `query_netman/4`, and `command_netman/5`; avoid a browser-facing generic target API.
- [ ] Persist the command before transport delivery and persist every terminal or unknown result.
- [ ] Store successful query results as snapshots before replying.
- [ ] Add `runtime_connected/3` and `runtime_disconnected/2` to update concrete status and return pending config plus unresolved command IDs.
- [ ] Re-run all tests in `yellow_dog_sync` and `yellow_dog_management_core`.
- [ ] Commit with `feat(management): add durable command transport state`.

### Task 8: Verify control-plane boundaries

**Files:**
- Modify only files required to resolve failures introduced by Tasks 1 through 7.

- [ ] Run `devenv shell -- mix format --check-formatted`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_sync mix compile --warnings-as-errors`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_sync mix test`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_management_core mix compile --warnings-as-errors`.
- [ ] Run `devenv shell -- mix cmd --app yellow_dog_management_core mix test`.
- [ ] Run `rg -n 'defmodule YellowDog\.(Domain\.Node|Management\.Node|Node)' apps docs`; expect no matches.
- [ ] Run `find apps -maxdepth 1 -type d \( -name yellow_dog_cloud_dns -o -name yellow_dog_local_server \)`; expect no output.
- [ ] Run `rg -n 'yellow_dog_store|YellowDog\.Store|Concord|Mnesia|Phoenix' apps/yellow_dog_sync apps/yellow_dog_management_core`; inspect every match and require no runtime dependency or call.
- [ ] Run `git diff --check`.
- [ ] Commit verification-only corrections with `fix(management): satisfy control plane guardrails` when corrections were needed. Do not create an empty commit.

## Completion Evidence

Record the exact command, exit status, and first actionable failure for any skipped or failing check. This plan is complete only when both apps pass their full test suites, restart durability is proven, and the dependency and forbidden-module scans are clean.
