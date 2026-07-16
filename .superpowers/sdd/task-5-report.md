# Task 5 Implementation Report

## Scope

Implemented Control Plane Task 5 on branch
`codex/service-node-remote-management` from base commit `92a2fa49`.

The implementation modifies the requested management-core source and test
files plus narrowly necessary management-core modules:
`lib/yellow_dog/management/manifest_store.ex` provides shared-manifest
serialization and `lib/yellow_dog/management/input_sanitizer.ex` normalizes
status values before persistence. The fourth-review fix also updates the Task 4
`lib/yellow_dog/management/storage/atomic_json.ex` helper and its focused test
to add owned same-directory staging plus no-clobber hard-link promotion, and
updates `event_store_hardening_test.exs` for tokenized event fixtures and
snapshotted limits. The required report is the only file outside
`apps/yellow_dog_management_core`. No Mnesia, database schema, protocol,
generic Node/target registry, dependency, console, or root `mix.exs` changes
were made by Task 5.

## Implementation

- `YellowDog.Management.Servers` persists each sanitized concrete `%Server{}`
  in the strict `"registration"` section of
  `management/servers/<id>/manifest.json`, reloads valid registration sections
  on startup, and ignores malformed registration-owned fields independently.
- `YellowDog.Management.Netmans` provides the corresponding separate concrete
  Netman registration section under `management/netmans/<id>/manifest.json`.
- `YellowDog.Management.ManifestStore` serializes atomic read-modify-write of
  top-level manifest sections. Registration owns only `"registration"`; Task 6
  can update `"config_lifecycle"` through the same helper without either task
  rejecting or clobbering the other section.
- Both registries preserve their existing facade return shapes, preserve
  `registered_at` during replacement, allow replacement when full, and publish
  Agent state only after manifest and event persistence succeeds.
- EventStore snapshots the validated storage root, file adapter, test hook,
  event limit, write bound, and transport margin into an owned named ETS table
  at startup. The table disappears with EventStore. `:event_write_timeout_ms`
  accepts `1..60_000` ms and otherwise falls back to 5000 ms. One operation
  uses one snapshot and deadline: event calls wait through `D + M`, manifest
  calls through `D + 2M`, and registry Agent calls through `D + 3M`.
- EventStore reserves the exact sequence, public event fields, 32-byte random
  commit token, deterministic content digest, final path, and unique staging
  path before any manifest side effect. Commit tokens are strict 43-character
  URL-safe strings on disk and remain internal to returned `%Event{}` values.
- The registration update and a strict bounded
  `"registration_audit_outbox"` marker are written in one atomic manifest
  replacement. The marker records the exact tokenized event, digest, desired
  registration digest, and previous registration or absence. Registry startup
  reconciles this marker before decoding or exposing registration state.
- ManifestStore owns event staging and promotion. A linked monitored worker
  writes, syncs, and closes only the known same-directory `.stage` path.
  ManifestStore then promotes with Linux same-filesystem `:file.make_link/2`,
  which is atomic and no-clobber. Every promotion return, error, exit, or
  exception is followed by a strict token, digest, and complete-content read of
  the final path. Final paths are never deleted by cancellation or collision.
- Exact final content commits the operation and permits clearing the outbox;
  absent or foreign content restores only the prior registration and clears
  the marker. Both paths re-read the current manifest so unrelated lifecycle
  sections survive. A process death after promotion or after outbox clear is
  reconciled by the enclosing caller as success; a death before promotion is
  recovered from the durable marker on registry restart.
- `ManifestStore` converts operation timeouts into the stable `:timeout`
  persistence error and other exceptions, throws, and process exits into the
  stable `:internal` error. An unavailable or crashing `EventStore` therefore
  does not terminate the manifest coordinator, concrete registry, or caller,
  and rollback still runs.
- `YellowDog.Management.EventStore` remains the global sequence/list owner,
  advances past occupied immutable filenames, and reconstructs allocation only
  from fully decoded tokenized records whose event identity matches the
  filename. Sequence gaps are accepted; sequence reuse after an allocator
  restart cannot match an older reservation because tokens differ.
- `list_events/0` traverses the event directory once, validates each candidate,
  and retains only the newest configured number of valid events in a bounded
  ordered set. It returns that slice in ascending
  `{sequence, occurred_at, id}` order without deleting older immutable files or
  repeatedly rescanning malformed backfill candidates.
- Event and registration-section decoding is strict about owned shape, enums,
  source/type coherence, filename identity, timestamps, paths, IDs, sequence,
  message, and metadata limits. Unrelated top-level manifest sections are
  accepted and preserved. Built-in status atoms remain atoms; arbitrary status
  atoms are normalized to bounded strings before state or disk publication.
  Arbitrary metadata atom keys and values are likewise normalized to bounded
  strings, while the established `:site` metadata key and built-in status enum
  values retain their existing representation. Decoding never creates atoms
  from disk.
- Limits use explicit application environment keys `:max_servers`,
  `:max_netmans`, and `:max_events`, with defaults `1000`, `1000`, and `500`.
  Invalid, non-positive, and oversized values fall back to those defaults.
  Registry limits cannot exceed 1000 and the event read limit cannot exceed the
  Sync list bound of 1000.

## TDD Evidence

### RED 1: Restart durability

Command:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && \
   mix test test/yellow_dog/management/restart_durability_test.exs'
```

Result: exit `2`, `1 test, 1 failure`. After restarting both registries,
`ManagementCore.get_server("srv-restart")` returned `{:error, :not_found}`.
This proved the original in-memory implementation lost registrations on
restart.

### RED 2: Failed-event manifest rollback

Command:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && \
   mix test test/yellow_dog/management/restart_durability_test.exs'
```

Result: exit `2`, `6 tests, 2 failures`. A failed replacement reloaded the
unpublished name `"After"`, and an immutable event conflict reloaded a failed
new registration. These failures drove compensating manifest rollback.

### GREEN: Focused rollback/durability suite

The same restart-durability command then passed with `6 tests, 0 failures`.

### RED 3: Shared manifest forward compatibility

After lifecycle keys were added to existing concrete manifests, the focused
restart suite failed with exit `2`, `7 tests, 1 failure`. Both registries logged
the manifests as malformed and `get_server/1` returned `{:error, :not_found}`.
This proved exact top-level key checks were incompatible with Task 6.

The regression was refined to the sectioned shared schema and a deterministic
concurrency test. The latter blocks immutable event creation, queues a
`"config_lifecycle"` update through `ManifestStore`, releases the event failure,
and proves registration rollback plus the queued lifecycle update both survive
restart. The focused suite then passed with `7 tests, 0 failures`.

## Review Fix TDD Evidence

The review fix was developed after Task 5 commit `8b87f08d`; that commit was
not amended.

### RED 4: EventStore process exits and sequence poisoning

The expanded restart suite initially failed with `10 tests, 5 failures`.
Stopping `EventStore` caused `ManifestStore` and `Servers` to exit through an
uncaught `GenServer.call/3` exit. A pre-existing malformed `evt-1.json` also
returned `:conflict` instead of advancing allocation, and the resulting process
failures cascaded into the remaining restart checks. This proved both the
failure isolation and create-collision defects.

### RED 5: Strict event decoding and bounded backfill

The new focused
`test/yellow_dog/management/event_store_hardening_test.exs` suite initially
failed with `2 tests, 1 failure`. Events with 21 metadata entries, traversal
source IDs, source/type mismatches, oversized metadata, pre-epoch or fractional
timestamps, and oversized sequences were exposed. The test also seeds malformed
newest candidates and requires `list_events/0` to fill the requested slice from
older valid immutable events.

### RED 6: Fresh-BEAM-safe status input

The custom-status regression initially failed because a newly created arbitrary
atom was returned and written as an atom. The replacement test proves the value
is normalized to a string in the returned server and manifest before restart,
then remains the same string after restart and in event metadata. This avoids a
fresh-BEAM dependency on `String.to_existing_atom/1`.

### RED 7: Oversized configured limits

The oversized-limit regression initially accepted a 1001st server when
`:max_servers` was configured as `1001`. The completed test covers the same
fallback for servers and Netmans and verifies an oversized `:max_events` setting
returns the documented newest 500-event slice.

### GREEN: Review regressions

Focused durability and event hardening command:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && \
   mix test test/yellow_dog/management/restart_durability_test.exs \
     test/yellow_dog/management/event_store_hardening_test.exs'
```

Result: exit `0`; `12 tests, 0 failures`. This includes deterministic
unavailable/crashing EventStore checks, registration rollback and restart,
collision advancement across multiple appends, malformed huge-filename restart,
strict event rejection, and bounded malformed-candidate backfill.

The former 50 ms `Task.yield/2` race was replaced with a mailbox barrier that
waits until the competing lifecycle `GenServer.call/3` is explicitly queued at
`ManifestStore` while event persistence is blocked. The test then releases the
failure and proves serialized lifecycle preservation; a non-serializing helper
cannot satisfy the queue assertion.

Focused facade command:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && \
   mix test test/yellow_dog/management_core_test.exs'
```

Result: exit `0`; `9 tests, 0 failures`, including custom-atom normalization
before write and oversized configured-limit fallback.

## Second Re-review Fix Evidence

The second review fix was developed after `52516a4f`; neither prior Task 5
commit was amended.

### RED 8: Equal nested mutation timeouts

A deterministic successful event write was blocked for 5.25 seconds, beyond
the former shared five-second defaults. The focused test failed because the
facade caller had exited and `Servers` terminated while its nested
`ManifestStore` call timed out. Releasing the blocked immutable create could
then complete outside the failed outer call, proving the delayed-orphan window.

### RED 9: Arbitrary atom metadata

Registering `%{rack: "r1", tier: :edge}` returned the atom-bearing map
unchanged instead of the durable canonical representation
`%{"rack" => "r1", "tier" => "edge"}`. The focused test failed before disk
restart or the fresh-BEAM check, proving normalization did not happen at the
input boundary.

### RED 10: Quadratic malformed backfill

The partial-fill event test seeds valid sequences `20` and `21`, malformed
sequences `2..19`, and the older valid sequence `1` with `:max_events` set to
three. BEAM call tracing counted `19` calls to `File.ls/1` for one
`list_events/0` operation instead of the required single traversal.

The three focused RED tests completed with exit `2`; `15 tests, 3 failures,
12 excluded`.

### GREEN: Second re-review regressions

At this review stage, the mutation chain used `:infinity` consistently for the
outer registry mutation, serialized manifest commit, and inner event append.
Missing and killed `EventStore` processes still returned immediately through
the existing caught exit path.

This historical implementation was subsequently superseded by the bounded
deadline and owned-worker design documented in the third re-review section.

The delayed test crosses the former deadline, confirms the facade caller and
original registry process are alive, releases the write, and verifies coherent
success in memory, manifest, immutable event history, and after restart.

The metadata test verifies canonical strings at registration and after registry
restart, then starts a fresh `mix run --no-compile --no-start` BEAM that loads
the same manifest and returns the exact canonical map without relying on atoms
created by the test process.

The event selector now performs one instrumented `File.ls/1` traversal and
retains only the newest three valid event records. The same focused command that
produced RED completed with exit `0`; `15 tests, 0 failures, 12 excluded`.

Complete durability and hardening files then passed with `15 tests, 0 failures`,
including unavailable and killed-EventStore rollback behavior.

## Third Re-review Fix Evidence

The third review fix was developed after Task 5 commit `01e5f906`; no prior
commit was amended.

### RED 11: Suspended EventStore request

The first regression configures `:event_write_timeout_ms` to 100 ms, suspends
the live EventStore, starts a facade registration, and proves its append request
is already queued in the EventStore mailbox. The old unbounded chain did not
return any result within the test's 500 ms bound.

### RED 12: Permanently slow started write

The second regression opens and writes the final event file, then blocks its
sync operation for 600 ms. The old implementation performed that filesystem
operation in EventStore itself and did not return within 500 ms. The focused
RED command completed with exit `2`; `13 tests, 2 failures, 11 excluded`.

### GREEN: Owned deadline and cancellation

Event append requests now carry the absolute deadline derived at the registry
entry point. The suspended EventStore request times out through the caller-side
transport margin, ManifestStore rolls back the registration section, and the
registry caller receives `%Error{code: :timeout}`. Servers, ManifestStore, and
the application supervisor remain the same live processes and are responsive
while EventStore is still suspended. After resume, the expired queued request
is processed as a no-op and cannot create a delayed event.

For a write that starts before the deadline, EventStore owns a linked monitored
worker. On timeout it sends the untrappable kill exit, waits for the monitor
`DOWN`, removes the newly created final event path, and then replies. The test
queues `list_events/0` while the valid-looking final file exists and proves the
list returns `[]` only after cleanup. A later registration succeeds, and after
waiting beyond the original 600 ms delay the only manifest/event belongs to
that later successful registration.

The focused command then completed with exit `0`; `13 tests, 0 failures,
11 excluded`. The complete restart durability file passed with
`13 tests, 0 failures`, retaining unavailable and killed-process rollback.

## Fourth Review and Durable-Outbox Evidence

The fourth-review work was developed after Task 5 commit `98ee7998`; no prior
commit was amended.

### RED 13: no owned staging/promotion primitive

The focused AtomicJson test required writing a unique same-directory staging
file, preserving an occupied final, and later promoting through a no-clobber
operation. It failed with exit `2`; `1 test, 1 failure`, because
`AtomicJson.stage/2` and `promote/2` were undefined.

### RED 14: worker wrote the final path

The first process-kill probe blocked after event sync and asserted the worker
path ended in `.stage`. It failed with exit `2`; `1 test, 1 failure`, because
the observed path was `events/evt-1.json`. This proved the worker still owned
the immutable final path.

### RED 15: expired ManifestStore work was not canceled

A deterministic suspended-ManifestStore test queued a section updater, waited
for its caller to receive a timeout, resumed the process, and required the
updater to remain uncalled. It failed with exit `2`; `3 tests, 1 failure`, after
receiving `:stale_manifest_updater_called`.

### RED 16: missing commit identity

A successful registration's immutable event was inspected for a bounded
cryptographic token. The focused test failed with exit `2`; `1 test, 1 failure`
because the eight-field event record had no `"commit_token"`.

### Durable boundary probes

The completed durability suite deterministically covers all ownership points:

- kill ManifestStore after the registration+outbox atomic replace and before
  staging; restart reconciliation restores the previous registration and
  retains unrelated manifest sections;
- kill ManifestStore while a fully synced staging worker is blocked; the linked
  worker dies, the restarted store removes the stale stage, and no final event
  is exposed;
- kill ManifestStore after final promotion but before outbox clear; exact token
  and complete-content reconciliation returns coherent success and startup
  clears the marker while keeping registration;
- kill ManifestStore after outbox clear but before reply; the enclosing caller
  reads the exact final and committed registration and returns success;
- write a foreign final with identical public fields and a different valid
  token; it is preserved, never treated as this attempt, and the next sequence
  succeeds;
- make the hard-link adapter create the final and then return `:eio` or raise;
  both outcomes reconcile as success from exact final content;
- reserve sequence 1, restart EventStore, reserve sequence 1 again, and prove
  the different token prevents the second reservation matching the first;
- suspend EventStore and ManifestStore separately past a 100 ms deadline and
  prove queued mutations later no-op while callers and registries remain alive;
- run a 5.2-second staged write under a snapshotted 6000 ms bound while
  EventStore list reads remain available and registry get/list calls wait past
  OTP's default five seconds without exiting;
- mutate timeout and storage-root environment values during operations and
  prove the startup snapshot remains in effect; terminating EventStore removes
  its ETS snapshot and restart loads the new bounded values;
- seed stale `.stage` files and prove restart cleanup never changes an existing
  immutable final.

The first complete run after the outbox implementation found one timeout-code
regression: a suspended ManifestStore returned `:internal` after an exact-final
check instead of preserving the transport `:timeout`. The focused regression
then passed after exact-final reconciliation retained its original fallback
code.

## Final Verification

Strict compile:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && \
   MIX_ENV=test mix compile --force --warnings-as-errors'
```

Result: exit `0`, with warnings treated as errors.

Production-mode strict compile also completed with exit `0`:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && \
   MIX_ENV=prod mix compile --force --warnings-as-errors'
```

Complete management-core suite:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && mix test'
```

Result: exit `0`; `53 tests, 0 failures`.

Owned-file format check:

```sh
devenv shell -- mix format --check-formatted \
  apps/yellow_dog_management_core/lib/yellow_dog/management/servers.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/netmans.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/event.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/event_store.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/input_sanitizer.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/manifest_store.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/storage/atomic_json.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management_core/application.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management_core.ex \
  apps/yellow_dog_management_core/test/yellow_dog/management_core_test.exs \
  apps/yellow_dog_management_core/test/yellow_dog/management/restart_durability_test.exs \
  apps/yellow_dog_management_core/test/yellow_dog/management/event_store_hardening_test.exs \
  apps/yellow_dog_management_core/test/yellow_dog/management/storage/atomic_json_test.exs
```

Result: exit `0`.

Strict Credo check:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && mix credo --strict'
```

Result: exit `0`; 37 checks across 22 source files found no issues.

Expected warning logs in malformed-file tests confirm that individual corrupt
manifests/events were ignored while valid state remained available.

## Concerns

The durable outbox closes the single-process/BEAM-kill transaction gap but does
not turn separate files into a power-loss transaction. The implementation
requires a local Linux filesystem supporting same-filesystem hard links with
atomic no-clobber semantics. Files are synced and closed before promotion, but
parent directories are not fsynced. A whole-host crash or power loss can still
violate the observed ordering of the manifest rename, hard link, and outbox
clear. In particular, a durable outbox with no exact final is safely rolled
back, and a durable exact final with an outbox is completed, but loss of a
supposedly completed hard link after a durable outbox clear remains within the
explicitly accepted whole-host/power-loss caveat.

If both event persistence and compensating manifest persistence fail, memory
remains unpublished and an error is logged, but manual disk repair may be
required. Task 6 section updates are protected when they use the serialized
`ManifestStore` interface; direct `AtomicJson.replace/2` calls must not be used
for shared manifests.
