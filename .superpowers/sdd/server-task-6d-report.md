# Server Task 6D Report: Netboot Control Adapter

## Status

Complete.

## Owned Changes

- Added `YellowDog.Server.Control.Netboot`.
- Added `YellowDog.ServerNetbootControlFake` and fixed owner facades.
- Added focused Netboot adapter and real Dispatcher tests.
- No Dispatcher production or test changes were required.

No Netboot owner, FileIndex, TFTP/iPXE, protocol, socket, console, application
dependency, or root Mix file was modified.

## Implementation

The adapter implements the fixed Server Sync operations:

- Managed profile, UUID-bearing device, and managed asset list queries.
- Managed profile put/delete.
- Durable device put/delete.
- Asset rescan for `all` and `missing`.
- Typed unsupported results for asset upload/delete and transfer/log lists.

Canonical reads are sorted, capped at 1,000 entries, revisioned before cursor
and limit pagination, and timestamped with the injected UTC clock. Profile
snapshots use only the versioned managed snapshot. Device projection omits
UUID-less legacy observations and hidden runtime state. Asset reads expose only
the owner-provided active ledger resources.

Profile and device `current/2` results use the same canonical wire resources as
successful mutations. Asset rescan revisioning uses only sorted
`filename`/`size` entries from the pre-scan FileIndex snapshot; absolute paths
are neither returned nor hashed.

The production owner modules are resolved only through the fixed
`Module.concat/1` values. Test overrides are restricted to the fixed dependency
keys and non-nil module atoms. The adapter introduces no compile-time Netboot
application dependency.

Owner absence and `:noproc`, conflicts, invalid snapshots/arguments,
apply/persistence failures, rollback failures, malformed replies, and
raise/throw/exit paths are converted to sanitized `YellowDog.Sync.Error`
values. The Dispatcher remains the only expected-revision and stale-revision
gate.

## TDD Evidence

The first focused run was executed before the production adapter existed:

```text
mix test test/yellow_dog/server/control/netboot_test.exs
11 tests, 10 failures
```

Failures were the expected missing `YellowDog.Server.Control.Netboot`
implementation and unsupported production route. After implementation and
fixture corrections against the exact owner/Sync schemas, the focused adapter
suite passed.

## Verification

All commands ran through `devenv`.

```text
cd apps/yellow_dog &&
mix test test/yellow_dog/server/control/netboot_test.exs \
  test/yellow_dog/server/control/dispatcher_test.exs
36 tests, 0 failures
```

```text
cd apps/yellow_dog && mix test
377 tests, 0 failures
```

```text
cd apps/yellow_dog && mix compile --warnings-as-errors
exit 0
```

```text
cd apps/yellow_dog && mix format --check-formatted
exit 0
```

```text
cd apps/yellow_dog && mix credo --strict
50 source files, found no issues
```

`git diff --check` also completed without errors for the owned files.

## Coverage

Focused tests cover:

- Deterministic sorting, 1,000-entry bounding, cursor/limit pagination,
  page-independent revision, and UTC observation time.
- Managed profile update/delete and configured runtime fallback rejection.
- Device UUID create/update/re-key/delete while projecting only public fields.
- Exact revisioned-resource and deleted-resource result schemas.
- Real Dispatcher stale revision rejection.
- Both asset rescan scopes, safe pre-scan revision input, exact counts, and no
  ledger snapshot or mutation calls.
- Validation-first typed unsupported behavior for upload, delete, transfers,
  and logs with no owner calls.
- Owner error mappings, malformed replies, raise/throw/exit handling, and
  invalid dependency overrides.
- Disabled and unavailable service short-circuits with zero owner,
  packet, or socket calls.

## Concerns

The fixed Sync `:filename` validator rejects path separators, so the adapter
accepts filename tokens such as `installer.img` but rejects nested relative
paths such as `images/installer.img`, even though the Netboot owner models
normalized relative filenames. Task 6D follows the required fixed Sync schema;
aligning those two contracts is outside this task's ownership.

## Post-Review Important Fixes

The Important findings in `server-task-6d-review.md` were addressed after the
reviewed Sync prerequisites landed:

- `dcde82aa fix(sync): allow normalized Netboot asset paths`
- `79ccb21b fix(sync): align Netboot filename control rules`

### Nested Netboot Paths

Managed asset list and FileIndex rescan coverage now use canonical nested paths
such as `images/installer.img` and `boot/a.img`. The adapter validates these
through the updated Sync normalized-relative-filename schema and returns the
owner asset unchanged. Real Dispatcher query and rescan paths are covered.

This resolves the earlier filename concern in this report. No remaining
adapter concern exists for normalized nested Netboot paths.

### Complete Rescan Revision State

Rescan `current/2` now returns this bounded canonical shape:

```text
%{
  "entry_count" => exact_complete_count,
  "entries_digest" => complete_sorted_entry_digest
}
```

The digest is the SHA-256 digest of the canonical JSON list streamed over every
sorted safe `%{"filename" => filename, "size" => size}` entry. It does not
truncate at 1,000 entries and never includes FileIndex absolute paths. Tests
cover 1,001 entries and prove that changing only entry 1,001 changes both the
current resource and Dispatcher revision, causing a stale expected revision to
be rejected before `control_rescan/1`.

Tests also prove that relocating the same filename/size entries to different
absolute paths leaves the current resource unchanged.

### Dependency Invocation Errors

`dependency_call/3` now loads the configured module and verifies the owner
entry point is exported before invocation. Missing modules or entry points map
to `not_found`. Once an exported owner call begins, all exceptions, throws, and
exits map to sanitized `apply_failed`, including an `UndefinedFunctionError`
raised from inside the exported facade.

### Post-Review TDD Evidence

The new focused regressions were run before the adapter fixes:

```text
cd apps/yellow_dog &&
mix test test/yellow_dog/server/control/netboot_test.exs
13 tests, 4 failures
```

The failures were the expected truncated list current resource and incorrect
`not_found` mapping for internal owner failures.

### Post-Review Verification

All commands ran through `devenv`.

```text
cd apps/yellow_dog &&
mix test test/yellow_dog/server/control/netboot_test.exs \
  test/yellow_dog/server/control/dispatcher_test.exs
39 tests, 0 failures
```

```text
cd apps/yellow_dog && mix test
380 tests, 0 failures
```

```text
cd apps/yellow_dog && mix compile --warnings-as-errors
exit 0
```

```text
cd apps/yellow_dog && mix format --check-formatted
exit 0
```

```text
cd apps/yellow_dog && mix credo --strict
50 source files, found no issues
```
