# Server Task 3B2 Report

## Scope

Phase 3B2 replaces the transaction-capable Zone replacement path with a durable,
roll-forward intent protocol. It preserves Phase 3B1 validation, exact snapshot
rules, shared zone locking, unchanged/reorder no-op behavior, public record event
semantics, and its compensating fallback for legacy backends without `txn/2`.

Changes are limited to Store keys/backends/Zone internals, two internal Zone
modules, focused Store tests/support, and this Phase 3B report. Protected console
files and root `mix.exs` remain untouched and unstaged.

## Durable Protocol

- Replacement headers use `store:zone-replacement:header:*`; immutable chunks
  use operation-scoped `store:zone-replacement:plan:*` keys. Neither can be
  mistaken for `dns:view:` metadata or RR changes.
- Headers fix version, operation ID, generation, exact scope, phase, base/target
  metadata, target serial, plan count/hash, next chunk, changed count, and event
  cursor. Active state has no TTL.
- Intent creation atomically compares the base zone and absent header. Preparing
  writes each chunk with create-only semantics and strongly verifies it before
  transitioning to applying. Definitively missing/corrupt preparing plans are
  safely removable; transient strong-read failures retain the intent for retry.
- Applying transactions compare the complete fenced header, perform at most 127
  mixed RR puts/deletes, and advance the cursor in the same transaction. Specs
  are conservatively capped at 900 KB under Concord's 1 MB limit.
- Finalization atomically writes the precomputed target metadata/serial once and
  moves to events. Unknown results, including malformed backend replies, resolve
  only by a strong header reread; serials are never recomputed. `execute/6`
  strongly verifies the exact target metadata before reporting success.
- Every event cursor first persists an immutable 24-hour event-log entry at
  `event_log:zone-replacement:{operation_id}:{cursor}`. Recovery then dispatches
  the persisted identity and advances the header cursor. Cursor zero is an
  internal commit event; later cursors retain existing per-RR EventBridge
  semantics. No precommit RR event is sent, and cleanup cannot remove replay data.
- Unknown transitions accept only a valid later state with identical immutable
  header fields and monotonic phase/cursor progress. Cleanup replays chunk
  deletion and fences header deletion by the exact header value.
- Every zone-scoped read/mutation invokes recovery under the same Phase 3B1
  `:global` lock. Post-recovery metadata/RR reads and scans use strong consistency.
  Lazy legacy ID persistence recovers again under its per-zone lock and keeps one
  captured backend through its CAS.

## Backend Guarantees

- `Backend.Cluster.txn/2` delegates to existing `Concord.Txn.commit/2` without an
  idempotency key. Its intents and chunks are restart durable.
- `Backend.Ets.txn/2` implements compare/success mixed operations for deterministic
  recovery after caller exits while the owning ETS table remains alive. It fully
  validates compares, both operation branches, limits, and encoded size before
  mutation. It does not claim VM-restart durability.
- Backends without `txn/2` use the preserved Phase 3B1 batch/compensation path,
  including `replace_failed` and `rollback_failed` contracts.

## TDD Evidence

Initial RED before production recovery APIs:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_recovery_test.exs'
exit 2: 5 tests, 5 failures
```

The failures were the missing recovery key, ETS transaction, durability, chunked
replacement, and oversized-record contracts.

Expanded crash/fault RED reached the protocol with three failures in unknown
outcome/barrier test plumbing, then passed after correction. A final compatibility
RED proved a backend without `txn/2` had lost Phase 3B1 compensation before the
narrow fallback was restored.

Independent-review regression RED, before the corrective production edits:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_recovery_test.exs'
exit 2: 26 tests, 9 failures
```

The nine failures independently reproduced transient preparing cleanup with a
false success, missing exact-target verification, asynchronous event persistence,
event write ambiguity, eventual post-recovery reads, lazy-ID backend/recovery
ordering, scanned-header key mismatch, weak transition fencing, and partial ETS
mutation before malformed-operation rejection.

Focused GREEN:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs test/yellow_dog/store/zone_recovery_test.exs test/yellow_dog/store/event_bridge_test.exs'
exit 0: 116 tests, 0 failures
```

Coverage includes exits after intent creation, plan persistence, every apply
chunk, final serial commit, event delivery, and cleanup; unknown outcomes before
and after commit; malformed transaction replies; missing/corrupt applying plans;
501/1001 records; count and byte chunking; old-or-new concurrent visibility;
legacy put/replace/delete fencing; one serial increment; no precommit events;
recovery idempotence; cleanup replay; durable event identity/replay; strong-read
option enforcement; and exact ETS caller-process durability behavior. The Cluster
test checks only the adapter's declared `:restart_durable` capability; it is not a
live Concord restart or multi-node visibility test.

## Verification

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test'
exit 0: 26 properties, 401 tests, 0 failures, 9 skipped

devenv shell -- bash -lc 'cd apps/yellow_dog_store && MIX_ENV=dev mix compile --force --warnings-as-errors'
exit 0: compiled 36 files; generated yellow_dog_store

devenv shell -- bash -lc 'cd apps/yellow_dog_store && MIX_ENV=test mix compile --force --warnings-as-errors'
exit 0: compiled 36 files; generated yellow_dog_store

devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix credo --strict'
exit 0: 62 source files, 755 mods/funs, no issues
```

Scoped `mix format --check-formatted` and `git diff --check` also pass. Existing
deprecated legacy Key API warnings remain in key/property tests and are unrelated.

## Limitations

- The Store Mix application has no application callback or independent ordered
  supervisor. The only current startup sequence is in out-of-scope
  `YellowDog.Application`, where recovery must run after `TaskSupervisor` and
  `EventBridge` but before consumers. This change therefore exposes synchronous
  `Zone.recover_pending_replacements/0` and recovers on every relevant access,
  but does not claim an automatic startup hook.
- Event cursor semantics are at least once. A crash after notification initiation
  and before cursor advancement may duplicate an already committed RR event. Such
  duplicates carry the same operation ID/cursor, and durable replay has one entry
  per cursor for the event-log retention period.
- The shared lock coordinates Zone facade callers. Direct backend writes remain
  outside the contract, but corrupt applying plans are detected and retained for
  operator repair rather than guessed or deleted.
- No live multi-node Concord cluster, node restart, or follower-staleness harness
  is available in this Store test suite. Cluster restart durability follows the
  Concord-backed adapter contract; executable visibility coverage here is ETS,
  facade-lock concurrency, and consistency-option verification.
