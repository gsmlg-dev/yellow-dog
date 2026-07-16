# Server Task 3B2 Report

## Scope

Phase 3B2 replaces the transaction-capable Zone replacement path with a durable,
roll-forward intent protocol. It preserves Phase 3B1 validation, exact snapshot
rules, shared zone locking, unchanged/reorder no-op behavior, public record event
semantics, and its compensating fallback for legacy backends without `txn/2`.

Changes are limited to Store keys/backends/Zone internals, two new internal Zone
modules, focused Store tests/support, and the Phase 3B documents. Protected
console files and root `mix.exs` remain untouched and unstaged.

## Durable Protocol

- Replacement headers use `store:zone-replacement:header:*`; immutable chunks
  use operation-scoped `store:zone-replacement:plan:*` keys. Neither can be
  mistaken for `dns:view:` metadata or RR changes.
- Headers fix version, operation ID, generation, exact scope, phase, base/target
  metadata, target serial, plan count/hash, next chunk, changed count, and event
  cursor. Active state has no TTL.
- Intent creation atomically compares the base zone and absent header. Preparing
  writes each chunk with create-only semantics and strongly verifies it before
  transitioning to applying. Incomplete preparing state is safely removable.
- Applying transactions compare the complete fenced header, perform at most 127
  mixed RR puts/deletes, and advance the cursor in the same transaction. Specs
  are conservatively capped at 900 KB under Concord's 1 MB limit.
- Finalization atomically writes the precomputed target metadata/serial once and
  moves to events. Unknown results, including malformed backend replies, resolve
  only by a strong header reread; serials are never recomputed.
- Committed RR telemetry/EventBridge notifications retain per-RR semantics and
  advance an at-least-once durable event cursor. No precommit RR event is sent.
  Cleanup replays chunk deletion and fences header deletion by exact generation.
- Every zone-scoped read/mutation invokes recovery under the same Phase 3B1
  `:global` lock. Zone lists strongly scan only intent headers and recover each
  matching scope before returning observable data.

## Backend Guarantees

- `Backend.Cluster.txn/2` delegates to existing `Concord.Txn.commit/2` without an
  idempotency key. Its intents and chunks are restart durable.
- `Backend.Ets.txn/2` implements compare/success mixed operations for deterministic
  recovery after caller exits while the owning ETS table remains alive. It does
  not claim VM-restart durability.
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

Focused GREEN:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs test/yellow_dog/store/zone_recovery_test.exs'
exit 0: 92 tests, 0 failures
```

Coverage includes exits after intent creation, plan persistence, every apply
chunk, final serial commit, event delivery, and cleanup; unknown outcomes before
and after commit; malformed transaction replies; missing/corrupt applying plans;
501/1001 records; count and byte chunking; old-or-new concurrent visibility;
legacy put/replace/delete fencing; one serial increment; no precommit events;
recovery idempotence; cleanup replay; and exact ETS/Cluster durability claims.

## Verification

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test'
exit 0: 26 properties, 392 tests, 0 failures, 9 skipped

devenv shell -- bash -lc 'cd apps/yellow_dog_store && MIX_ENV=dev mix compile --force --warnings-as-errors'
exit 0: compiled 36 files; generated yellow_dog_store

devenv shell -- bash -lc 'cd apps/yellow_dog_store && MIX_ENV=test mix compile --force --warnings-as-errors'
exit 0: compiled 36 files; generated yellow_dog_store

devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix credo --strict'
exit 0: 62 source files, 716 mods/funs, no issues
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
  and before cursor advancement may duplicate an already committed RR event.
- The shared lock coordinates Zone facade callers. Direct backend writes remain
  outside the contract, but corrupt applying plans are detected and retained for
  operator repair rather than guessed or deleted.
