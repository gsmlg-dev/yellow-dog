# Server Task 6C Report: Managed Netboot Asset Ledger

## Status

Complete against the revised Task 6C brief and decisions dated 2026-07-17.

This report supersedes every earlier Task 6C claim that control deletion moves,
tombstones, restores, unlinks, or otherwise mutates payload files.

## Security Decision

The TFTP root is operator-writable. A pathname can therefore be replaced after
content or inode verification and before a path-based move or unlink takes
effect. The prior FileOps/GNU `mv` design could detect some replacements after
the transition, but it could not guarantee that no untracked file had already
been moved or deleted.

The safe foundation consequently performs no physical remote/control delete.
Physical deletion is deferred until managed payloads live in an authenticated,
agent-owned namespace with exclusive lifecycle ownership.

## Implemented Behavior

### Active-only managed ledger

- `YellowDog.Netboot.Asset.ManagedAsset` accepts exactly six fields:
  `asset_id`, `filename`, `size`, `blob_digest`, `ownership`, and `lifecycle`.
- The only accepted ownership and lifecycle values are `"managed"` and
  `"active"`.
- Obsolete `"tombstoned"` lifecycle values and any `tombstone_filename` field
  are rejected. Startup never attempts to recover them.
- Asset IDs are bounded, normalized UTF-8 without path separators or Unicode
  control characters.
- Filenames are bounded, normalized safe relative paths without traversal,
  absolute forms, backslashes, duplicate separators, dot segments, NULs, or
  Unicode control characters.
- Size is a bounded non-negative integer. The digest is exactly 64 lowercase
  hexadecimal SHA-256 characters.
- `YellowDog.Netboot.Asset.Ledger` rejects duplicate IDs and filenames on load
  and mutation and serializes entries deterministically by asset ID.
- The versioned JSON ledger remains outside the TFTP root and uses the approved
  `YellowDog.Netboot.ManagedStorage.AtomicJson`.

### Control API boundary

- `control_snapshot/1` returns deterministic active ledger-owned resources
  only. Disk discovery never creates managed IDs, ownership, or digests.
- `control_delete_asset/1` and `/2` validate the asset ID.
- A valid existing or missing ID returns `{:error, :unsupported}`.
- A malformed ID returns `{:error, :invalid}`.
- The handler does not inspect the ledger for existence and invokes no file,
  ledger-write, FileIndex-mutation, or broadcast operation.
- Remote upload remains unsupported at the unchanged control boundary.

Focused regressions compare the Store process state, raw ledger bytes, full
FileIndex snapshot, and payload bytes before and after control delete for both
an existing managed ID and a missing valid ID.

### Local console compatibility

- `upload_file/2` remains exported and preserves parent-directory creation,
  local copy, overwrite, traversal rejection, and native source errors.
- `delete_file/1` remains exported and preserves local path deletion, traversal
  rejection, and native file errors.
- These local APIs are intentionally distinct from the unsupported remote
  control boundary.

### FileIndex and restart

- Every successful `Asset.Store` init loads and validates the ledger, discovers
  the complete TFTP root, and activates a full FileIndex snapshot.
- A Store-only restart recreates its ETS table and indexes both managed and
  untracked safe regular files, so a one-for-one restart does not leave an
  empty live index.
- Protocol lookup reads remain unchanged.
- `build_snapshot/2`, `snapshot/0`, and validated `replace/1` remain as the
  narrow deterministic index-owner seam.
- The obsolete per-path `FileIndex.remove/1` compensation operation was
  removed.

### List and rescan

- Local listing reports all safe regular files without claiming ownership.
- `"all"` rescans count every safe regular file discovered, then replace the
  complete FileIndex.
- `"missing"` rescans compare discovered filenames with the pre-scan index,
  count only previously absent files, then replace the complete FileIndex.
- Symlinks and non-regular files are skipped.
- Both scopes leave the ledger byte-for-byte unchanged.
- Discovery failure preserves the active index and returns
  `{:error, :apply_failed}`.

## Removed Unsafe Surfaces

- Deleted `YellowDog.Netboot.Asset.FileOps`.
- Deleted all GNU `mv`, tombstone move, restore, verification, unlink, and
  recovery code.
- Deleted tombstone lifecycle/model fields and derived path calculations.
- Deleted ledger replace/delete operations used only by physical deletion.
- Deleted max-derived-tombstone, `preserve_tombstoned`, rollback-failed, and
  delete-compensation failure surfaces.
- Deleted FileOps fault/race support and physical-deletion tests.
- Retained only persisted obsolete-state rejection tests required by the
  revised contract.

## TDD Evidence

The revised tests were written and run before production changes.

RED result:

```text
57 tests, 6 failures
```

The failures proved:

- the model and ledger still accepted `"tombstoned"` entries;
- Store startup still recovered an obsolete tombstoned document;
- an existing control delete still removed the managed asset;
- a missing valid ID returned `:not_found` instead of typed unsupported;
- malformed string IDs were looked up rather than strictly validated.

After removing the unsafe machinery and implementing the non-mutating boundary,
the same focused command was GREEN:

```text
57 tests, 0 failures
```

Coverage includes active-only and obsolete-state validation, duplicate/path/
digest/control-character validation, deterministic snapshots, untracked files,
existing and missing control deletes, malformed delete requests, local upload
and delete compatibility, Store-only restart, failed discovery compensation,
and both rescan scopes.

## Verification

All commands ran through `devenv`.

Focused asset and FileIndex tests:

```text
cd apps/yellow_dog_netboot &&
mix test test/asset/managed_asset_test.exs \
  test/asset/ledger_test.exs \
  test/asset/store_test.exs \
  test/tftp/file_index_test.exs
```

Result: 57 tests, 0 failures.

Full Netboot tests:

```text
cd apps/yellow_dog_netboot && mix test
```

Result: 392 tests, 0 failures.

Warnings-as-errors compile:

```text
cd apps/yellow_dog_netboot && mix compile --force --warnings-as-errors
```

Result: 22 files compiled, exit 0.

Formatting:

```text
cd apps/yellow_dog_netboot && mix format --check-formatted
```

Result: exit 0.

Strict Credo:

```text
cd apps/yellow_dog_netboot && mix credo --strict
```

Result: 48 source files, 615 modules/functions, no issues.

The full suite emits its existing deliberate ScriptEngine missing-assign
warning and expected unavailable-test-root warnings. Neither is a failure. An
earlier non-forced compile also surfaced an unrelated warning in concurrently
modified `yellow_dog_config` code; the forced Netboot compile above was clean,
and no out-of-scope file was changed.

## Scope Confirmation

Changes are limited to Task 6C-owned asset modules, the narrow FileIndex owner
surface, focused tests/support, and this report. Supervisor, profiles, devices,
TFTP handlers/server/transfers/iPXE/packet/socket code, Server adapters,
console, Mix files, protocol code, and protected files were not modified by
this task.

## Remaining Concern

Remote physical asset deletion is intentionally unavailable. It must not be
implemented against the operator-writable TFTP tree; it requires the future
authenticated, agent-owned payload namespace described in the revised
decisions.
