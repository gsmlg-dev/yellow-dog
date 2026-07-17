# Server Task 7C Report: Identity Server Control Adapter

Date: 2026-07-17

## Scope

Implemented the fixed Identity Server control adapter without changing the
Dispatcher, Identity owner, Sync schemas, Config, console, protocols, or root
Mix configuration.

Owned files:

- `apps/yellow_dog/lib/yellow_dog/server/control/identity.ex`
- `apps/yellow_dog/test/support/server_identity_control_fake.ex`
- `apps/yellow_dog/test/yellow_dog/server/control/identity_control_test.exs`
- `.superpowers/sdd/server-task-7c-report.md`

## Implementation

`YellowDog.Server.Control.Identity` implements the five lossless fixed
operations:

- `server.identity.hosts.list`
- `server.identity.audit.list`
- `server.identity.hosts.approve`
- `server.identity.hosts.revoke`
- `server.identity.hosts.delete`

Host and audit lists are fully validated before any bound is applied, sorted by
their fixed IDs, bounded to the Sync collection limit, revisioned over the
complete bounded list before pagination, and timestamped through the injected
clock. Host snapshots are accepted only when their fixed `revision` equals the
canonical Server revision of the exact owner map.

Host `current/2` calls only `YellowDogIdentity.control_host/1`, validates the
canonical owner map, confirms the requested ID, and returns that exact map.
Approve and revoke validate both prior and resulting snapshots, require the
fixed state transition and stable host identity/name, and return the exact
resulting owner map in `revisioned_resource`. Delete validates the durable prior
snapshot and uses that snapshot's revision in the fixed `deleted_resource`.
Expected revisions are not inspected by the adapter; the existing Dispatcher
remains the sole gate.

The six owner-model gaps validate against the fixed Sync payload schema and
then return the typed `unsupported` error without resolving or calling an
owner:

- `server.identity.approvals.list`
- `server.identity.tokens.list`
- `server.identity.policies.get`
- `server.identity.tokens.create`
- `server.identity.tokens.revoke`
- `server.identity.policies.update`

No approval ID, token ID, label, action, policy collection, or token secret is
fabricated.

## Dependency Boundary

Production resolution uses `Module.concat(["YellowDogIdentity"])`; the
`yellow_dog` app has no compile-time `yellow_dog_identity` dependency. Test
overrides are available only in `Mix.env() == :test`, accept only the fixed
`identity` and `clock` keys, and require non-nil module atoms.

The adapter uses only the final public owner facade:

- `control_list_hosts/0`
- `control_list_audit/0`
- `control_host/1`
- `control_approve_host/1`
- `control_revoke_host/1`
- `control_delete_host/1`

It does not inspect Identity structs, Registry state, files, token storage, or
approval-engine configuration.

## Failure And Disclosure Safety

Missing owner modules/functions and owner absence/noproc map to fixed
`not_found`. Owner conflicts, already-revoked results, and invalid host states
map to fixed `conflict`. Explicit invalid owner errors and malformed public
maps map to fixed `invalid`. Persistence/owner failures, malformed return
envelopes, exceptions, throws, and non-noproc exits map to fixed
`apply_failed`.

Every emitted error has a fixed message and empty details. Tests inject raw
paths, token hashes, one-time secrets, SSH material, audit details, structs,
exceptions, throws, and exits and confirm none crosses the adapter or
Dispatcher result. Unsupported token operations make zero owner calls.

## TDD Evidence

The focused tests and fake were added before production code. After correcting
a test-fixture syntax error and bypassing an unrelated in-progress
ServerAgent dependency compile, the intentional RED run was:

```text
mix test --no-compile test/yellow_dog/server/control/identity_control_test.exs --seed 0
# 11 tests, 9 failures
```

The failures were the absent adapter's undefined direct calls and the
Dispatcher's unsupported route result.

After implementing the adapter:

```text
mix test --no-compile test/yellow_dog/server/control/identity_control_test.exs --seed 0
# 11 tests, 0 failures
```

The final normal focused run, after concurrent dependency work settled, was:

```text
mix test test/yellow_dog/server/control/identity_control_test.exs --seed 0
# 11 tests, 0 failures
```

Coverage includes all eleven fixed operations through the real Dispatcher,
all three supported stale-revision paths, exact current snapshots, deterministic
list bounds/revisions/pagination, disabled and unavailable service gates,
validation-first unsupported behavior, fixed owner resolution, invalid owner
returns, and disclosure safety.

## Verification

All commands ran through the repository devenv:

```text
cd apps/yellow_dog
mix test test/yellow_dog/server/control/identity_control_test.exs --seed 0
# 11 tests, 0 failures

mix test --seed 0
# 404 tests, 0 failures

MIX_ENV=test mix compile --force --warnings-as-errors
# Compiling 33 files; exit 0

MIX_ENV=test mix credo --strict \
  lib/yellow_dog/server/control/identity.ex \
  test/support/server_identity_control_fake.ex \
  test/yellow_dog/server/control/identity_control_test.exs
# 3 files, 99 mods/funs, found no issues

mix format --check-formatted \
  apps/yellow_dog/lib/yellow_dog/server/control/identity.ex \
  apps/yellow_dog/test/support/server_identity_control_fake.ex \
  apps/yellow_dog/test/yellow_dog/server/control/identity_control_test.exs
# exit 0
```

## Self Review

- Every production branch begins with fixed operation-schema validation.
- List revisions exclude observation time and pagination and include the
  complete bounded canonical resource set.
- Host resource revisions are owner-provided but independently verified.
- Mutation transitions cannot swap host IDs, names, or states.
- Delete does not invent a post-delete host and preserves the deleted prior
  resource revision.
- Unsupported paths do not resolve dependencies or call owner functions.
- Dispatcher locking, routing, normalization, and revision code are unchanged.
- No generic Node API, protocol edit, raw UDP, migration, direct Concord call,
  local path, or token material was added.
- Concurrent console, root Mix, Settings, and ServerAgent work was not staged,
  modified, or reverted by this task.

## Concerns

None in the owned Task 7C surface.
