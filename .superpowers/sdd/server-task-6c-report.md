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

## Independent Review Remediation

This section supersedes the original report where behavior changed in response
to `.superpowers/sdd/server-task-6c-review.md`.

### C1: deterministic, globally exclusive tombstones

- Persisted `tombstone_filename` must now equal
  `ManagedAsset.tombstone_filename/1` for that exact asset.
- Every asset reserves two owned paths even while active: its payload and its
  deterministic same-directory tombstone.
- `Ledger.put/2`, `Ledger.replace/2`, and ledger loading reject intersections
  between any payload/tombstone pair as `:duplicate_asset_path`, in addition to
  the existing duplicate ID and duplicate payload checks.
- An asset whose own payload equals its derived tombstone is invalid.
- The exact C1 malicious restart ledger is covered: tombstoned asset `a`
  persists `b.img` while active asset `b` owns `b.img`, and both entries use
  identical bytes. Startup rejects the ledger as
  `:invalid_tombstone_filename` and proves `b.img` remains unchanged.

### C2: verified no-replace transitions

- Added the asset-scoped Linux file boundary
  `YellowDog.Netboot.Asset.FileOps`.
- A transition opens and verifies the source as a regular file, binds the open
  descriptor to the path by Linux device/inode identity, and streams its size
  and SHA-256 before transition.
- The same-directory move uses GNU coreutils
  `mv --update=none-fail --no-copy -T`, which fails when the target exists and
  cannot fall back to copying.
- The source descriptor remains open across the transition. Afterward, the
  target is reopened and revalidated for device/inode identity, size, digest,
  and stable final path identity.
- The same primitive is used for payload-to-tombstone moves, rollback restore,
  active-ledger startup restore, and tombstoned resume. Restore never replaces
  a concurrently created payload.
- Tombstone removal also revalidates descriptor identity and content
  immediately before removal. A replacement detected at that boundary is left
  untouched.
- On ambiguous source identity/content, Store removes both owned paths from
  FileIndex and leaves the filesystem bytes and durable ledger state
  non-destructively recoverable.
- Deterministic race coverage creates a target after source verification,
  swaps the source after verification, mutates the same inode after
  verification, and replaces a tombstone before removal. Tests assert exact
  bytes at every surviving path.

### I1: failed restore remains tombstoned and non-serving

- Rollback removes the asset payload/tombstone from FileIndex before attempting
  restoration.
- Only a proven payload restore, required ledger compensation, and prior-index
  replacement restore the active state.
- If restore fails, Store durably writes or re-writes the tombstoned candidate,
  rebuilds FileIndex with both the payload and tombstone excluded, retains the
  tombstoned in-memory state, and returns `:rollback_failed`.
- Coverage injects an index activation failure and creates an untracked payload
  at the restore target. The untracked payload is not overwritten, managed
  bytes remain at the tombstone, both TFTP lookups return `:not_found`, the
  control snapshot is empty, and restart completes recovery after the
  conflicting untracked path is removed.
- A second test combines the initial candidate-ledger write failure with the
  same restore conflict and proves the retry persists tombstoned state.

### I2: complete FileIndex rebuild on every Store init

- Every `Asset.Store` init initializes and clears FileIndex before ledger
  recovery, then rebuilds the complete root snapshot after recovery.
- Startup excludes both paths of every durable tombstoned asset.
- A Store-only restart regression proves the Store-owned ETS table is
  destroyed, recreated, and repopulated with both managed and untracked safe
  files while the rest of the supervision tree remains untouched.

### I3: local compatibility APIs restored

- `upload_file/2` again creates parent directories and copies a local source,
  including legacy overwrite behavior.
- `delete_file/1` again removes a local relative path and returns native file
  errors.
- Both local APIs retain traversal rejection.
- Remote/control upload remains unsupported in the unchanged control adapter;
  control deletion remains asset-ID based and ledger-owned only.

### M1: explicit control-character rejection

- Asset IDs and filenames now reject Unicode control code points (`\p{Cc}`),
  including newline, tab, carriage return, and escape, rather than relying only
  on `String.printable?/1`.

## Review TDD Evidence

RED was recorded before production changes. The normal focused command first
encountered unrelated, concurrently edited `Device.Registry` compile errors
outside Task 6C ownership. Running the focused files against the existing test
build without starting the unrelated supervision tree produced:

```text
68 tests, 16 failures
```

The failures included control-character acceptance, arbitrary tombstone
acceptance, missing global path reservation, missing asset file-ops module,
malicious-ledger startup success, local API regressions, source/target races,
empty FileIndex after Store-only restart, and stale active state after failed
restore.

GREEN focused verification:

```text
cd apps/yellow_dog_netboot &&
mix test test/asset/managed_asset_test.exs \
  test/asset/ledger_test.exs \
  test/asset/file_ops_test.exs \
  test/asset/store_test.exs \
  test/tftp/file_index_test.exs
```

Result: 70 tests, 0 failures.

## Review Verification

All final commands ran through `devenv`.

```text
cd apps/yellow_dog_netboot && mix test
```

Final result: 405 tests, 0 failures.

An earlier full run at seed `537193` had two order-dependent failures in
`Boot.DhcpIntegrationTest` while the unowned `Device.Registry` files were being
modified concurrently. That test file passed independently (5 tests,
0 failures), and the complete rerun at seed `568363` passed. No device or boot
files were changed by Task 6C.

```text
cd apps/yellow_dog_netboot && mix compile --force --warnings-as-errors
```

Result: 23 files compiled, exit 0.

```text
mix compile --warnings-as-errors
mix format --check-formatted
```

Result: both exit 0.

```text
cd apps/yellow_dog_netboot && mix credo --strict
```

Result: 51 source files, 691 modules/functions, no issues.

The full suite still emits the existing intentional EEx missing-assign warning
from `ScriptEngine` coverage and expected warnings for unavailable test TFTP
roots; neither produces a test or compile failure.
