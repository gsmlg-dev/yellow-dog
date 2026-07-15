# Task 5 Implementation Report

## Scope

Implemented Control Plane Task 5 on branch
`codex/service-node-remote-management` from base commit `92a2fa49`.

The implementation modifies the requested management-core source and test
files plus one narrowly necessary storage coordinator:
`lib/yellow_dog/management/manifest_store.ex`. The required report is the only
file outside `apps/yellow_dog_management_core`. No Mnesia, database schema,
protocol, generic Node/target registry, dependency, console, or root `mix.exs`
changes were made.

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
- `YellowDog.Management.EventStore` is supervised before both registries. It
  serializes global sequence allocation, writes immutable `evt-<sequence>.json`
  files before returning events, and reconstructs the next sequence from disk
  after restart.
- `list_events/0` reads valid immutable event files, sorts by the durable total
  key `{sequence, occurred_at, id}`, and returns the newest configured bounded
  slice in ascending order without deleting older event files.
- Event and registration-section decoding is strict about owned shape, enums,
  timestamps, paths, and bounded values. Unrelated top-level manifest sections
  are accepted and preserved. Typed scalar encoding preserves atom/string
  metadata and statuses without creating new atoms from untrusted disk content.
- Limits use explicit application environment keys `:max_servers`,
  `:max_netmans`, and `:max_events`, with defaults `1000`, `1000`, and `500`.
  Invalid and non-positive values fall back to those defaults.

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

## Final Verification

Strict compile and complete management-core tests:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && \
   mix compile --force --warnings-as-errors && \
   MIX_ENV=test mix test'
```

Result: exit `0`; 16 files compiled with warnings treated as errors, followed
by `26 tests, 0 failures`.

Owned-file format check:

```sh
devenv shell -- mix format --check-formatted \
  apps/yellow_dog_management_core/lib/yellow_dog/management/servers.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/netmans.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/event.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/event_store.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management/manifest_store.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management_core/application.ex \
  apps/yellow_dog_management_core/lib/yellow_dog/management_core.ex \
  apps/yellow_dog_management_core/test/yellow_dog/management_core_test.exs \
  apps/yellow_dog_management_core/test/yellow_dog/management/restart_durability_test.exs
```

Result: exit `0`.

Strict Credo check:

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_management_core && mix credo --strict'
```

Result: exit `0`; 37 checks across 21 source files found no issues.

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
