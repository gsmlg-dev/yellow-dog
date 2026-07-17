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
- Every event cursor first persists a stable pending record at
  `event_log:zone-replacement:{operation_id}:{cursor}` with no TTL. Recovery may
  then advance the header cursor and clean its intent. EventBridge strongly scans
  pending records at startup, retries transient backend unavailability, dispatches
  automatically when a matching subscriber registers, and acknowledges dispatch
  with an exact-value transaction before starting the 24-hour replay retention.
  A crash before acknowledgement replays the same operation ID/cursor identity.
  Cursor zero is an acknowledged internal commit audit event; later cursors retain
  existing per-RR EventBridge semantics. No precommit RR event is sent.
- Event recovery strongly loads and hashes all immutable plan chunks once per
  recovery invocation, then indexes the verified operation tuple by cursor. A
  restart revalidates once; processing is `O(chunks + events)` rather than
  repeatedly reloading the whole plan for every event.
- Unknown transitions accept only a valid later state with identical immutable
  header fields and monotonic phase/cursor progress. Cleanup replays chunk
  deletion and fences header deletion by the exact header value.
- Every zone-scoped read/mutation invokes recovery under the same Phase 3B1
  `:global` lock. Post-recovery metadata/RR reads and scans use strong consistency.
  Lazy legacy ID persistence derives the authoritative view/origin from the
  scanned key, rejects key/payload mismatches before locking or writing, recovers
  again under that exact per-zone lock, and keeps one captured backend through
  its CAS.

## Backend Guarantees

- `Backend.Cluster.txn/2` delegates to existing `Concord.Txn.commit/2` without an
  idempotency key. Its intents and chunks are restart durable.
- `Backend.Ets.txn/2` implements compare/success mixed operations for deterministic
  recovery after caller exits while the owning ETS table remains alive. It fully
  validates compares, both operation branches, supported option sets, positive
  integer TTLs, limits, encoded size, and Concord-safe values before mutation. It
  returns an error without raising or partially writing for malformed operations.
  It does not claim VM-restart durability.
- Backends without `txn/2` use the preserved Phase 3B1 batch/compensation path,
  including `replace_failed` and `rollback_failed` contracts.
- The transaction-backed facade also normalizes internal recovery failures into
  the documented `replace_failed` public shape while retaining the detailed
  recovery reason inside it.

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

Second-review regression RED, before the corrective production edits:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/event_bridge_test.exs test/yellow_dog/store/zone_recovery_test.exs'
exit 2: 44 tests, 5 failures
```

The failures reproduced loss of a persisted event across EventBridge restart,
valid-put/invalid-TTL partial transaction behavior, a key-A/payload-B legacy ID
scope violation, leaked `recovery_failed` facade errors, and quadratic event-plan
reads (`8016` strong chunk reads for 1001 changes instead of `8`). The first full
suite run also supplied RED for startup ordering: EventBridge raised when started
before the ETS table (`404 tests, 6 failures`) rather than staying available and
retrying the pending-event scan.

Focused GREEN:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs test/yellow_dog/store/zone_recovery_test.exs test/yellow_dog/store/event_bridge_test.exs'
exit 0: 119 tests, 0 failures
```

Coverage includes exits after intent creation, plan persistence, every apply
chunk, final serial commit, event delivery, and cleanup; unknown outcomes before
and after commit; malformed transaction replies; missing/corrupt applying plans;
501/1001 records; count and byte chunking; old-or-new concurrent visibility;
legacy put/replace/delete fencing; one serial increment; no precommit events;
recovery idempotence; cleanup replay; durable event identity/replay; strong-read
option enforcement; automatic pending-event replay after EventBridge restart;
transaction option prevalidation; key-derived legacy scope fencing; linear event
plan reads (`8` chunks for 1001 changes); public error normalization; and exact ETS
caller-process durability behavior. The Cluster test checks only the adapter's
declared `:restart_durable` capability; it is not a live Concord restart or
multi-node visibility test.

## Verification

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test'
exit 0: 26 properties, 404 tests, 0 failures, 9 skipped

devenv shell -- bash -lc 'cd apps/yellow_dog_store && MIX_ENV=dev mix compile --force --warnings-as-errors'
exit 0: compiled 36 files; generated yellow_dog_store

devenv shell -- bash -lc 'cd apps/yellow_dog_store && MIX_ENV=test mix compile --force --warnings-as-errors'
exit 0: compiled 36 files; generated yellow_dog_store

devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix credo --strict'
exit 0: 62 source files, 797 mods/funs, no issues
```

Scoped `mix format --check-formatted` and `git diff --check` also pass. The full
test run emits existing deprecated legacy Key API warnings in key/property tests,
plus expected EventBridge retry warnings from the startup-order coverage; neither
is a compiler warning or test failure.

## Limitations

- The Store Mix application has no application callback or independent ordered
  supervisor. The only current startup sequence is in out-of-scope
  `YellowDog.Application`, where recovery must run after `TaskSupervisor` and
  `EventBridge` but before consumers. This limitation applies to scanning Zone
  replacement intents: Store exposes synchronous
  `Zone.recover_pending_replacements/0` and also recovers on every relevant
  access, but does not claim an automatic Zone-intent startup hook. It does not
  limit EventBridge: every EventBridge start automatically scans pending durable
  events and retries a temporarily unavailable backend.
- Event cursor semantics are at least once. Pending records do not expire; after
  fan-out acknowledgement they remain replayable for 24 hours. A crash after
  dispatch and before acknowledgement may duplicate an RR event with the same
  operation ID/cursor. EventBridge subscriptions are process-local and must
  re-register after bridge restart (Store's monitored consumers already do so);
  registration automatically dispatches matching pending records without a
  manual replay call. Acknowledgement covers subscribers matching at that
  dispatch, not a durable per-consumer offset. Function callbacks retain the
  existing asynchronous contract and are acknowledged when their supervised task
  is accepted.
- The shared lock coordinates Zone facade callers. Direct backend writes remain
  outside the contract, but corrupt applying plans are detected and retained for
  operator repair rather than guessed or deleted.
- No live multi-node Concord cluster, node restart, or follower-staleness harness
  is available in this Store test suite. Cluster restart durability follows the
  Concord-backed adapter contract; executable visibility coverage here is ETS,
  facade-lock concurrency, and consistency-option verification.
