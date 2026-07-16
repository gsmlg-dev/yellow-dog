# Server Task 3B1 Interim Report

## Scope

Phase 3B1 hardens the existing compensating `YellowDog.Store.Zone.replace_records/3`
implementation. It intentionally excludes durable intents, caller/backend exit
recovery, and restart recovery; those belong to Phase 3B2.

Changed files are limited to the Zone facade, narrow Key validation helpers,
focused Zone tests, and the test-only failure backend. Pre-existing changes in
the protected console files and root `mix.exs` were left untouched and unstaged.

## Design

- `Key.canonical_zone_scope/2` and `Key.canonical_owner/1` validate key safety but
  return every segment verbatim. Case and optional trailing root dots are neither
  folded nor removed, so historical Store keys remain addressable without a
  migration. Delimiters, malformed UTF-8, whitespace, and invalid DNS labels are
  rejected before locking.
- RR type validation accepts any existing atom whose encoded text is nonempty,
  bounded, valid UTF-8, and free of `:` and control characters. It does not create
  atoms and therefore preserves historical types such as `:sshfp` without a
  partial allowlist.
- Desired records are fully validated before locking. Duplicate detection uses
  the final verbatim `Key.zone_rr/4` string, not a normalized tuple.
- Every legacy Zone mutation uses one exact `{view, zone}` `:global` lock:
  auth/forward/stub create, update, delete, RR put/delete, import, serial mutation,
  lazy zone-ID backfill, and replacement. Private locked helpers avoid recursion.
- Replacement requires `zone_type: :auth` and `authoritative: true`, then takes a
  complete strong RR-prefix snapshot. Every snapshot entry must have verbatim
  owner/type/rrset/zone/class metadata and exactly match its expected RR key.
- RRset member order is normalized only for equality. Changed desired RRsets are
  persisted exactly as supplied; reorder-only replacements cause no write,
  serial, telemetry, or EventBridge churn.
- Apply and restore `put_many/1` calls are split into at most 500 operations.
  Every returned result map must contain exactly the requested keys with every
  value equal to `:ok`.
- Any apply/delete/serial failure restores all prior RR values, attempts removal
  of every introduced key even after an earlier removal fails, retains the first
  rollback error, and verifies the exact prior snapshot with a second strong scan.
  A serial may advance after an ambiguous backend error but is never rolled back.
- Both `:aborted` and `{:aborted, reason}` lock results return a bounded lock error;
  replacements wrap that as `{:error, {:replace_failed, ...}}`.
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

Reviewer-repair RED before the compatibility and exhaustive-cleanup production
changes:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs'
exit 2: 75 tests, 6 failures
```

Failures covered verbatim legacy metadata/RR lookup, distinct case-sensitive
persisted keys, SSHFP put/get/delete/import/replace, and cleanup continuing after
the first introduced-key deletion failure.

Final focused GREEN:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs'
exit 0: 75 tests, 0 failures
```

Coverage also proves empty/unchanged/add/update/delete/mixed counts, one serial
increment, partial put restoration, stale delete failure after one deletion,
new-key removal failure, verification-scan failure, compensation failure,
500/501 boundaries (including a partial write in the failing later chunk),
replace-versus-replace serialization, different-zone independence, committed
telemetry/EventBridge ordering, and explicit subscription cleanup.

## Verification

```text
devenv shell -- bash -lc 'mix format apps/yellow_dog_store/lib/yellow_dog/store/key.ex apps/yellow_dog_store/lib/yellow_dog/store/zone.ex apps/yellow_dog_store/test/support/failure_backend.ex apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs'
exit 0

devenv shell -- bash -lc 'cd apps/yellow_dog_store && mix test'
exit 0: 26 properties, 375 tests, 0 failures, 9 skipped
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
  recovery is explicitly deferred to Phase 3B2, whose design must use
  fencing/generation checks so stale workers cannot advance a recovered plan.
- The shared lock coordinates callers using the Zone facade; direct backend writes
  to Zone keys remain outside that contract.
- EventBridge dispatch and event-log persistence remain asynchronous, matching the
  existing Store API. Phase 3B1 guarantees notification initiation only after the
  replacement and serial update succeed, not durable exactly-once delivery.
