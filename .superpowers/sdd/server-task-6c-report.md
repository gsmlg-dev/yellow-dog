# Server Task 6C Report: Managed Netboot Asset Ledger

## Status

Complete.

## Scope

Implemented only the Task 6C-owned Netboot asset ledger, asset owner, narrow
FileIndex compensation seam, focused tests/support, and this report.

No Supervisor, profile, device, packet, TFTP handler/server/transfer, iPXE,
socket, Server adapter, console, application dependency, or root Mix files were
modified by this task.

## Implementation

### Versioned managed asset ledger

- Added `YellowDog.Netboot.Asset.ManagedAsset`.
- Added `YellowDog.Netboot.Asset.Ledger`.
- The ledger is a strict JSON object:

  ```json
  {
    "version": 1,
    "assets": []
  }
  ```

- Active entries contain exactly:
  - `asset_id`
  - normalized relative `filename`
  - bounded non-negative `size`
  - lowercase 64-character SHA-256 `blob_digest`
  - `ownership: "managed"`
  - `lifecycle: "active"`
- Tombstoned entries additionally contain a normalized same-directory
  `tombstone_filename` and use `lifecycle: "tombstoned"`.
- Loading and every ledger mutation revalidate the complete document.
- Duplicate asset IDs and payload filenames are rejected.
- IDs are bounded, valid normalized UTF-8, printable, and cannot be path forms.
- Filenames must be normalized relative paths without traversal, absolute
  prefixes, backslashes, NUL bytes, duplicate separators, or dot segments.
- Unknown fields, versions, ownership values, lifecycle values, invalid sizes,
  and malformed/uppercase digests are rejected.
- Persistence uses the approved
  `YellowDog.Netboot.ManagedStorage.AtomicJson`.

The default ledger path is the TFTP root's sibling
`managed_assets.json`. Tests can configure `managed_assets_path`. Startup
rejects any ledger path inside the TFTP payload tree.

### Asset owner APIs

`YellowDog.Netboot.Asset.Store` now owns the loaded ledger and exposes:

- `control_snapshot/0`: deterministic active managed resources only.
- `control_delete_asset/1`: asset-ID based managed deletion.
- `control_rescan/1`: exact `"all"` or `"missing"` discovery count.
- `managed_assets_path/0`: owner path inspection.

Control snapshots are derived only from active ledger entries. Files discovered
on disk are never assigned IDs, digests, ownership, or lifecycle state.

Upload remains `{:error, :unsupported}` because no authenticated blob resolver
exists. Legacy path deletion is also unsupported so it cannot remove an
untracked operator file.

### Recoverable delete state machine

Managed delete performs the following ordering:

1. Fetch an active ledger entry by stable asset ID.
2. Verify the current regular payload's exact size and streaming SHA-256.
3. Refuse deletion when the deterministic tombstone path already exists.
4. Snapshot the active FileIndex.
5. Rename the payload to a deterministic same-directory tombstone.
6. Durably write the tombstoned candidate ledger with `AtomicJson`.
7. Build a complete candidate FileIndex excluding the owned tombstone.
8. Activate the rebuilt FileIndex.
9. Remove the tombstone.
10. Durably write the final ledger without the deleted entry.

Before index activation, failures compensate the payload path, prior ledger,
and prior FileIndex. Compensation refuses to overwrite a concurrently created
path and reports `:rollback_failed` when complete restoration is impossible.

After candidate activation, tombstone-removal or final-ledger failures leave a
durable tombstoned entry. A retry or process restart resumes deterministically.
Startup also recovers the interruption window after payload rename but before
candidate-ledger persistence.

An untracked file is never deleted or overwritten. Payload replacement,
tombstone collisions, ambiguous interrupted states, and digest/size mismatch
are conflicts.

### FileIndex owner seam

Added narrow owner operations without changing lookup/protocol reads:

- `build_snapshot/2`: non-mutating deterministic disk discovery with exact
  exclusions.
- `snapshot/0`: deterministic active ETS snapshot.
- `replace/1`: validated complete replacement.

`scan/1` now builds and validates a candidate before replacing ETS, so a failed
scan preserves the active index. Discovery uses `File.lstat/1` and skips
symlinks and non-regular files.

### Rescan semantics

- `"all"` counts every safe regular file in the candidate disk snapshot, then
  replaces FileIndex.
- `"missing"` compares candidate filenames with the pre-scan FileIndex, counts
  only absent filenames, then replaces FileIndex.
- Both scopes leave the ledger byte-for-byte unchanged.
- Managed tombstones are excluded from serving and rescan counts.

## TDD Evidence

RED cycles were observed for:

- missing `ManagedAsset` and `Ledger` modules;
- missing FileIndex snapshot/build/replace operations;
- missing Store owner APIs and startup ledger validation;
- root-level tombstone normalization;
- injected payload, ledger, index, cleanup, and rollback failures;
- ledger-inside-root validation when the TFTP root is `/`.

GREEN coverage includes:

- restart ledger load and strict malformed/duplicate validation;
- active-only deterministic managed snapshots;
- untracked file preservation and unsupported upload/path delete;
- payload digest/size replacement conflicts;
- successful tombstone deletion and final ledger cleanup;
- candidate-ledger failure rollback;
- index activation failure and deterministic index rollback;
- tombstone removal failure plus restart recovery;
- final ledger failure plus retry recovery;
- failed compensation plus startup recovery;
- interrupted active and tombstoned lifecycle states;
- tombstone collision preservation;
- `all` and `missing` rescan counts;
- symlink exclusion and failed-rescan index preservation.

## Verification

All commands ran through `devenv`.

```text
cd apps/yellow_dog_netboot &&
mix test test/asset/managed_asset_test.exs \
  test/asset/ledger_test.exs \
  test/asset/store_test.exs \
  test/tftp/file_index_test.exs
```

Result: 59 tests, 0 failures.

```text
cd apps/yellow_dog_netboot && mix test
```

Result: 372 tests, 0 failures.

```text
mix compile --warnings-as-errors
```

Result: exit 0.

```text
mix format --check-formatted
```

Result: exit 0.

```text
cd apps/yellow_dog_netboot && mix credo --strict
```

Result: 49 source files, 585 modules/functions, no issues.

The full test run emits the existing intentional EEx missing-assign warning
from `ScriptEngine` coverage; it does not produce a test failure or compile
warning.

## Integration Notes

- There is intentionally no managed asset creation API in Task 6C. The ledger
  can be populated only by a future authenticated blob workflow.
- Task 6D should consume `control_snapshot/0`,
  `control_delete_asset/1`, and `control_rescan/1`.
- Existing console upload and path-delete calls now receive
  `{:error, :unsupported}`. Console changes were outside this task's ownership.
