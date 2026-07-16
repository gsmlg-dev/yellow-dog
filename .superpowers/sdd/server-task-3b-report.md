# Server Task 3B1 Interim Report

## Scope

Phase 3B1 hardens the existing compensating `YellowDog.Store.Zone.replace_records/3`
implementation. It intentionally excludes durable intents, caller/backend exit
recovery, and restart recovery; those belong to Phase 3B2.

Changed files are limited to the Zone facade, narrow Key validation helpers,
focused Zone tests, and the test-only failure backend. Pre-existing changes in
the protected console files and root `mix.exs` were left untouched and unstaged.

## Design

- `Key.canonical_zone_scope/2` and `Key.canonical_owner/1` lowercase names,
  remove one optional DNS root dot, validate labels, and reject `:` delimiter
  collisions, whitespace, malformed UTF-8, invalid labels, and unsupported RR
  types. Existing persisted key formats are unchanged.
- Desired records are fully canonicalized and validated before locking. Duplicate
  detection uses the final `Key.zone_rr/4` string, not the caller's raw tuple.
- Every legacy Zone mutation uses one canonical `{view, zone}` `:global` lock:
  auth/forward/stub create, update, delete, RR put/delete, import, serial mutation,
  lazy zone-ID backfill, and replacement. Private locked helpers avoid recursion.
- Replacement requires `zone_type: :auth` and `authoritative: true`, then takes a
  complete strong RR-prefix snapshot. Every snapshot entry must have canonical
  owner/type/rrset/zone/class metadata and exactly match its expected RR key.
- RRset member order is normalized only for equality. Changed desired RRsets are
  persisted exactly as supplied; reorder-only replacements cause no write,
  serial, telemetry, or EventBridge churn.
- Apply and restore `put_many/1` calls are split into at most 500 operations.
  Every returned result map must contain exactly the requested keys with every
  value equal to `:ok`.
- Any apply/delete/serial failure restores all prior RR values, removes introduced
  keys, and verifies the exact prior snapshot with a second strong scan. A serial
  may advance after an ambiguous backend error but is never rolled backward.
- RR operation telemetry, RR-change telemetry, and EventBridge notifications are
  emitted only after all RR mutations and the single serial increment succeed.

## TDD Evidence

Focused RED after removing Phase 3B2-only crash/intent cases and before production
repair:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs'
exit 2: 70 tests, 13 failures
```

The failures covered canonical scope lookup, invalid delimiter rejection,
persisted-key duplicates, `authoritative: false`, malformed snapshots, RRset
reordering, incomplete/extra batch maps, 501-item chunking, later-chunk failure,
and same-zone put/delete/import/delete-zone races.

Final focused GREEN:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs'
exit 0: 70 tests, 0 failures
```

Coverage also proves empty/unchanged/add/update/delete/mixed counts, one serial
increment, partial put restoration, stale delete failure after one deletion,
new-key removal failure, verification-scan failure, compensation failure,
500/501 boundaries, different-zone independence, and committed telemetry and
EventBridge ordering.

## Verification

```text
devenv shell -- bash -lc 'mix format apps/yellow_dog_store/lib/yellow_dog/store/key.ex apps/yellow_dog_store/lib/yellow_dog/store/zone.ex apps/yellow_dog_store/test/support/failure_backend.ex apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs'
exit 0

devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test'
exit 0: 26 properties, 370 tests, 0 failures, 9 skipped
note: existing deprecated Key API warnings were emitted by key/property tests

devenv shell -- bash -lc 'cd apps/yellow_dog_store && MIX_ENV=dev mix compile --force --warnings-as-errors'
exit 0: compiled 34 files; generated yellow_dog_store

devenv shell -- bash -lc 'cd apps/yellow_dog_store && MIX_ENV=test mix compile --force --warnings-as-errors'
exit 0: compiled 34 files; generated yellow_dog_store

devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix credo --strict'
exit 0: 59 source files, 624 mods/funs, no issues

devenv shell -- bash -lc 'mix format --check-formatted apps/yellow_dog_store/lib/yellow_dog/store/key.ex apps/yellow_dog_store/lib/yellow_dog/store/zone.ex apps/yellow_dog_store/test/support/failure_backend.ex apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs'
exit 0

git diff --check -- .superpowers/sdd/server-task-3b-report.md apps/yellow_dog_store/lib/yellow_dog/store/key.ex apps/yellow_dog_store/lib/yellow_dog/store/zone.ex apps/yellow_dog_store/test/support/failure_backend.ex apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs
exit 0
```

One earlier full-suite run had one lock test time out while waiting only one second
after the explicit backend barrier was released. The helper's completion window
was increased to five seconds without changing its blocked-state assertion; the
focused and full suites then passed as shown above.

## Limitations

- Phase 3B1 is not crash-safe. If the replacing process or backend exits after a
  partial non-atomic mutation, compensation may not run. Durable intent/cursor
  recovery is explicitly deferred to Phase 3B2.
- The shared lock coordinates callers using the Zone facade; direct backend writes
  to Zone keys remain outside that contract.
- EventBridge dispatch and event-log persistence remain asynchronous, matching the
  existing Store API. Phase 3B1 guarantees notification initiation only after the
  replacement and serial update succeed, not durable exactly-once delivery.
