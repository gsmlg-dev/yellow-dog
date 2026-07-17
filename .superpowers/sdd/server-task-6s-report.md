# Server Task 6S Report

## Status

Implemented the Netboot-only normalized relative-filename Sync schema type.

## Changes

- `netboot_asset_upload` and `netboot_asset` now use
  `:normalized_relative_filename`.
- Nested normalized relative paths are accepted for Netboot upload payloads,
  upload results, and asset-list results.
- The validator rejects absolute, drive, UNC, backslash, NUL/control, empty,
  dot, dot-dot, duplicate-separator, trailing-separator, non-NFC, and
  oversized values.
- The generic `:filename` validator remains unchanged and retains leaf-name
  behavior for DNS import metadata.

## Verification

- TDD red: the nested-path payload test failed against the prior leaf-only
  validator.
- TDD green: the same test passed after the Netboot-only schema change.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_sync && mix test test/yellow_dog/sync/server_operation_test.exs'`
  passed: 40 tests, 0 failures.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_sync && mix test'`
  passed: 111 tests, 0 failures.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_sync && mix compile --warnings-as-errors'`
  passed.
- `devenv shell -- bash -lc 'mix format --check-formatted apps/yellow_dog_sync/lib/yellow_dog/sync/operation.ex apps/yellow_dog_sync/test/yellow_dog/sync/server_operation_test.exs'`
  passed.
- Strict Credo passed for the two changed Sync files.

## Concern

The full umbrella strict Credo run reports 13 existing refactoring findings in
`apps/yellow_dog_management_core`, outside this task's ownership. No Sync
finding was reported.

## Review Fix

- Narrowed the dedicated Netboot filename category check from `\p{C}` to
  `\p{Cc}`, matching `ManagedAsset`.
- Added payload and list-result parity coverage for NFC nested filenames
  containing U+E000 private-use, U+00AD soft hyphen, and U+200D format
  characters.
- Added explicit rejection coverage for newline, tab, escape, and NUL control
  characters.
- Kept generic `:filename` behavior unchanged.

## Review Fix Verification

- TDD red:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_sync && mix test test/yellow_dog/sync/server_operation_test.exs:1032'`
  failed on the private-use filename under the prior `\p{C}` rule.
- TDD green: the same focused command passed after changing the rule to
  `\p{Cc}`.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_sync && mix test test/yellow_dog/sync/server_operation_test.exs'`
  passed: 41 tests, 0 failures.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_sync && mix test'`
  passed: 112 tests, 0 failures.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_sync && mix compile --warnings-as-errors'`
  passed.
- `devenv shell -- bash -lc 'mix format --check-formatted apps/yellow_dog_sync/lib/yellow_dog/sync/operation.ex apps/yellow_dog_sync/test/yellow_dog/sync/server_operation_test.exs'`
  passed.
- `devenv shell -- bash -lc 'mix run --no-start -e
  '\''Mix.Tasks.Credo.run(["--strict",
  "apps/yellow_dog_sync/lib/yellow_dog/sync/operation.ex",
  "apps/yellow_dog_sync/test/yellow_dog/sync/server_operation_test.exs"])'\'''`
  passed: 2 files checked, no issues.
