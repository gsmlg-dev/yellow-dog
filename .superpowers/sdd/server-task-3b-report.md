# Server Task 3B Report

## Scope

Implemented `YellowDog.Store.Zone.replace_records/3` in the Store facade only,
with focused tests and a process-local failure-injecting backend that delegates
normal storage to `YellowDog.Store.Backend.Ets`.

Protected console files and the root `mix.exs` were not edited, staged, or
reverted.

## Design

- Validate the full desired RRset list, record shape, and duplicate
  `{owner, type}` keys before backend writes.
- Serialize replacements for the same `{view, zone}` with a `:global` lock.
- Read the zone metadata and complete prior RRset snapshot with strong
  consistency through the active `YellowDog.Store.Backend`.
- Compare semantic RRset content, preserving unchanged records without
  timestamp, serial, telemetry, or EventBridge churn.
- Batch changed/new RRsets with `put_many/1`, delete stale keys in deterministic
  key order, and increment the SOA serial once after all RRset writes succeed.
- Emit existing Store operation telemetry, RR-change telemetry, and EventBridge
  notifications only after the RRset replacement and serial update commit.
- On apply or serial failure, restore every prior key/value, remove every newly
  introduced key, and verify the exact prior snapshot with a second strong scan.
  Return `replace_failed` only after that verification succeeds; otherwise
  return `rollback_failed` with apply and rollback reasons.
- Compensation never writes zone metadata, so an ambiguously successful serial
  update may advance the serial but is never rolled backward.

## TDD Evidence

RED, before production implementation:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs'
exit 2: 52 tests, 13 failures
Expected failure: YellowDog.Store.Zone.replace_records/3 was undefined or private.
```

First complete GREEN run after implementation and fixture corrections:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs'
exit 0: 52 tests, 0 failures
```

Coverage includes empty, unchanged, add, update, delete, mixed change counts,
duplicate/invalid/missing/non-auth zero-write rejection, one serial increment,
partial batch put failure, stale delete failure, ambiguous serial failure, exact
content restoration, new-key removal, compensation failure, and EventBridge
commit ordering. The same file retains and runs all prior Zone API tests.

## Verification

```text
devenv shell -- bash -lc 'mix format apps/yellow_dog_store/lib/yellow_dog/store/zone.ex apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs apps/yellow_dog_store/test/support/failure_backend.ex'
exit 0

devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix credo --strict'
exit 0: 59 source files, 577 mods/funs, no issues

devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test'
exit 0: 26 properties, 352 tests, 0 failures, 9 skipped
Note: existing deprecated Key API warnings were emitted by key/property tests.

devenv shell -- bash -lc 'cd apps/yellow_dog_store && MIX_ENV=dev mix compile --force --warnings-as-errors'
exit 0: compiled 34 files, generated yellow_dog_store

devenv shell -- bash -lc 'cd apps/yellow_dog_store && MIX_ENV=test mix compile --force --warnings-as-errors'
exit 0: compiled 34 files, generated yellow_dog_store

devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs'
exit 0: 52 tests, 0 failures

devenv shell -- bash -lc 'mix format --check-formatted apps/yellow_dog_store/lib/yellow_dog/store/zone.ex apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs apps/yellow_dog_store/test/support/failure_backend.ex'
exit 0

git diff --check -- apps/yellow_dog_store/lib/yellow_dog/store/zone.ex apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs apps/yellow_dog_store/test/support/failure_backend.ex
exit 0

git diff --cached --check
exit 0 after staging exactly the four owned files
```

## Limitations

- The Backend behaviour has no transaction spanning batch puts, individual
  deletes, and serial CAS. This facade provides failure atomicity through
  compensation and exact strong-read verification; the zone lock serializes
  concurrent `replace_records/3` calls, but legacy RR mutation APIs do not
  participate in that lock.
- EventBridge delivery and durable event-log persistence remain asynchronous,
  matching existing Store behavior; notification is initiated only after the
  replacement commit.
