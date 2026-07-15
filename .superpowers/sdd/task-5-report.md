# Task 5 Implementation Report

## Scope

Implemented Control Plane Task 5 on branch
`codex/service-node-remote-management` from base commit `92a2fa49`.

The implementation modifies the requested management-core source and test
files plus two narrowly necessary management-core modules:
`lib/yellow_dog/management/manifest_store.ex` provides shared-manifest
serialization and `lib/yellow_dog/management/input_sanitizer.ex` normalizes
status values before persistence. The required report is the only file outside
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
- If event persistence fails after a registration-section write,
  `ManifestStore` restores only the previous registration section or removes
  that section for a new registration. It re-reads the current manifest during
  rollback so unrelated sections are retained, and helper-based lifecycle
  updates serialize behind the entire registration/event operation. This
  prevents a later registry restart from exposing unpublished registration
  state without overwriting lifecycle state.
- `ManifestStore` converts exceptions, throws, and process exits from the
  post-manifest event commit into the stable `:internal` persistence error.
  An unavailable or crashing `EventStore` therefore does not terminate the
  manifest coordinator, concrete registry, or caller, and rollback still runs.
- `YellowDog.Management.EventStore` is supervised before both registries. It
  serializes global sequence allocation, writes immutable `evt-<sequence>.json`
  files before returning events, advances past create-only filename collisions,
  and reconstructs the next sequence only from fully decoded records whose
  event identity matches their filename.
- `list_events/0` retains only a configured-size candidate filename set while
  scanning each batch, decodes only bounded batches, and backfills from older
  candidates when newer files are malformed. It returns the newest configured
  valid slice sorted by `{sequence, occurred_at, id}` without deleting older
  immutable event files.
- Event and registration-section decoding is strict about owned shape, enums,
  source/type coherence, filename identity, timestamps, paths, IDs, sequence,
  message, and metadata limits. Unrelated top-level manifest sections are
  accepted and preserved. Built-in status atoms remain atoms; arbitrary status
  atoms are normalized to bounded strings before state or disk publication, and
  decoding never creates atoms from disk.
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

## Final Verification

Strict compile:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && \
   MIX_ENV=test mix compile --warnings-as-errors'
```

Result: exit `0`, with warnings treated as errors.

Complete management-core suite:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && mix test'
```

Result: exit `0`; `33 tests, 0 failures`.

Owned-file format check:

```sh
devenv shell -- mix format --check-formatted \
  apps/yellow_dog_management_core/lib/yellow_dog/management/servers.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/netmans.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/event.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/event_store.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/input_sanitizer.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/manifest_store.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management_core/application.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management_core.ex \
  apps/yellow_dog_management_core/test/yellow_dog/management_core_test.exs \
  apps/yellow_dog_management_core/test/yellow_dog/management/restart_durability_test.exs \
  apps/yellow_dog_management_core/test/yellow_dog/management/event_store_hardening_test.exs
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

The manifest/event pair cannot be made fully transactional with separate files.
The implementation compensates for a returned event-write failure by restoring
only the registration section. If the BEAM or host crashes after the manifest
rename but before immutable event completion, the process cannot execute that
compensation; restart may therefore observe the advanced registration section
without its audit event. Likewise, if both event persistence and compensating
filesystem persistence fail, memory remains unpublished and an error is logged,
but manual disk repair may be required. Task 6 section updates are protected
from Task 5 rollback when they use the shared serialized `ManifestStore` API;
direct `AtomicJson.replace/2` calls must not be used for shared manifests.
