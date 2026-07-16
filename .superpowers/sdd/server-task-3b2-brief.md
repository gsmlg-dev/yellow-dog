# Server Task 3B2: Crash-Safe Zone Replacement Recovery

## Goal

Make the Phase 3B replacement observationally crash-safe when a caller or
backend exits between RR mutations, stale deletes, and SOA serial activation.
Retain all Phase 3B1 validation, locking, compensation, and public contracts.

## Backend Facts

- Concord transactions support mixed put/delete/compare atomically, but permit
  at most 64 compares, 128 operations per branch, and a 1 MB encoded spec.
- `put_many` permits at most 500 records.
- Do not rely on Concord transaction `idempotency_key`; its documented option is
  not consumed by the current state machine.
- Cluster mode can persist recovery state. ETS mode can recover caller-process
  exits while the table survives but is not durable across a VM restart.

## Durable Intent Protocol

- Add intent/header and immutable plan-chunk keys outside `dns:view:` so DNS
  reload subscriptions and zone metadata scans cannot misclassify them.
- A header records version, operation ID, exact view/zone, phase, base and target
  zone metadata, fixed target serial, plan count/hash, next chunk, changed count,
  and event state. Active intents have no TTL.
- `preparing`: create the header only against the expected base zone, write and
  verify every immutable plan chunk, then mark applying. Incomplete preparation
  may be removed because no RR mutation has begun.
- `applying`: each transaction compares operation/phase/cursor, applies a mixed
  chunk, and advances the cursor in that same transaction.
- Finalize: atomically write the precomputed SOA metadata exactly once and mark
  events pending. Never recompute the serial during recovery.
- Cleanup: deliver the idempotent committed event/telemetry at least once, then
  remove chunks and header idempotently.

## Chunking And Unknown Results

- Reserve one transaction operation for cursor advancement; use at most 127 RR
  mutations and a conservative encoded-size bound below 1 MB per chunk.
- Reject one record that cannot fit with a typed `record_too_large` error.
- On timeout/unknown outcome, strongly reread the header. An advanced cursor
  means committed; otherwise replay the same immutable chunk.

## Recovery And Visibility

- Under the shared Phase 3B1 zone lock, recover before every relevant zone read
  or mutation. Strong reads must fail closed when recovery cannot complete.
- Add the smallest Store-owned startup recovery child if Store supervision can
  guarantee recovery before consumers. Scan only intent-header keys, recover
  synchronously, and preserve corrupt/incomplete applying intents for repair.
- Reads may return only a complete old or complete committed state; never expose
  a partially applied plan.
- Do not emit per-RR events during chunks. After finalization emit one
  replacement/zone activation signal sufficient for idempotent reload, unless
  existing public contracts require a durable per-RR cursor.

## Tests

Inject exits after intent creation, plan chunks, each apply chunk, final serial,
event delivery, and cleanup; cover unknown transaction outcomes, corrupt/missing
chunks, 501/1001 records, byte-size chunking, concurrent old-or-new reads,
legacy mutation recovery, one serial increment, no precommit events, idempotent
recovery, startup ordering, and ETS-versus-Cluster durability claims.

## Constraints

Keep changes inside Store keys/backends/zone replacement/recovery/supervision and
focused tests. No Server adapter, DNS packet/runtime, UDP, Sync schema, migration,
generic RPC/Node, or protected user-file changes. No upstream Concord issue is
needed unless implementation chooses to depend on the broken idempotency option.

## Implementation Outcome

- Implemented durable replacement headers and immutable plan chunks under
  `store:zone-replacement:*`, outside all `dns:view:` subscriptions and scans.
- Added backend compare/mixed-operation transactions. Cluster delegates to
  `Concord.Txn`; ETS provides deterministic caller-process recovery while its
  table survives. Legacy backends without `txn/2` retain the Phase 3B1
  compensating implementation and public errors.
- Added fixed target serial/metadata, plan count/hash, 127-operation and 900 KB
  transaction bounds, strong cursor resolution, generation fencing, replayable
  per-RR event progress, and idempotent cleanup.
- Every Zone facade read and mutation now recovers the exact zone under the
  shared Phase 3B1 lock. Global zone lists scan only replacement headers first.
- Cluster intents are restart durable and can be recovered synchronously through
  `Zone.recover_pending_replacements/0`; automatic startup invocation is not
  wired because the ordered `ModeDetector -> TaskSupervisor -> EventBridge`
  supervision point is owned by `YellowDog.Application`, outside this task's
  Store-only scope. ETS makes no VM-restart durability claim.
